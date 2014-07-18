# encoding: utf-8

module Cql
  class Cluster
    class Client
      include MonitorMixin

      attr_reader :keyspace

      def initialize(driver)
        @driver                      = driver
        @logger                      = driver.logger
        @registry                    = driver.cluster_registry
        @reactor                     = driver.io_reactor
        @request_runner              = driver.request_runner
        @load_balancing_policy       = driver.load_balancing_policy
        @reconnection_policy         = driver.reconnection_policy
        @connections_per_local_node  = driver.connections_per_local_node
        @connections_per_remote_node = driver.connections_per_remote_node
        @connecting_hosts            = ::Set.new
        @connections                 = ::Hash.new {|hash, host| hash[host] = Cql::Client::ConnectionManager.new}
        @prepared_statements         = ::Hash.new
        @keyspace                    = nil
        @state                       = :idle

        mon_initialize
      end

      def connect(hosts)
        synchronize do
          return CLIENT_CLOSED     if @state == :closed || @state == :closing
          return @connected_future if @state == :connecting || @state == :connected

          @state = :connecting

          @connected_future = begin
            futures = hosts.map do |host|
              f = @reactor.execute do
                @connecting_hosts << host
                @load_balancing_policy.distance(host)
              end
              f = f.flat_map {|distance| connect_to_host(host, distance)}
              f.recover do |error|
                @connecting_hosts.delete(host)
                Cql::Client::FailedConnection.new(error, host)
              end
            end

            Future.all(*futures).map do |connections|
              connections.flatten!
              raise NO_HOSTS if connections.empty?

              unless connections.any?(&:connected?)
                errors = {}
                connections.each {|c| errors[c.host] = c.error}
                raise NoHostsAvailable.new(errors)
              end

              self
            end
          end
          @connected_future.on_complete(&method(:connected))
          @connected_future
        end
      end

      def close
        synchronize do
          return @closed_future if @state == :closed || @state == :closing

          state, @state = @state, :closing

          @closed_future = begin
            if state == :connecting
              f = @connected_future.recover.flat_map { close_connections }
            else
              f = close_connections
            end

            f.map(self)
          end
          @closed_future.on_complete(&method(:closed))
          @closed_future
        end
      end

      def connected(f)
        if f.resolved?
          synchronize do
            @state = :connected
          end

          @registry.add_listener(self)
          @logger.info('Cluster connection complete')
        else
          synchronize do
            @state = :defunct
          end

          f.on_failure do |e|
            @logger.error('Failed connecting to cluster: %s' % e.message)
          end

          close
        end
      end

      def closed(f)
        synchronize do
          @state = :closed

          @registry.remove_listener(self)

          if f.resolved?
            @logger.info('Cluster disconnect complete')
          else
            f.on_failure do |e|
              @logger.error('Cluster disconnect failed: %s' % e.message)
            end
          end
        end
      end

      # These methods shall be called from inside reactor thread only
      def host_found(host)
        nil
      end

      def host_lost(host)
        nil
      end

      def host_up(host)
        return Future.resolved if @connecting_hosts.include?(host)

        @connecting_hosts << host

        f = connect_to_host_maybe_retry(host, @load_balancing_policy.distance(host))
        f.map(nil)
      end

      def host_down(host)
        return Future.resolved if @connecting_hosts.delete?(host) || !@connections.has_key?(host)

        @prepared_statements.delete(host)
        futures = @connections.delete(host).snapshot.map {|c| c.close}

        Future.all(*futures).map(nil)
      end

      def query(statement, options = {})
        request = Protocol::QueryRequest.new(statement.cql, statement.params, options[:type_hints], options[:consistency], options[:serial_consistency], options[:page_size], options[:paging_state], options[:trace])
        timeout = options[:timeout]

        f = @reactor.execute { @load_balancing_policy.plan(@keyspace, statement) }
        f.flat_map {|plan| send_request_by_plan(request, plan, timeout)}
      end

      def prepare(cql, options = {})
        request = Protocol::PrepareRequest.new(cql, options[:trace])
        timeout = options[:timeout]

        f = @reactor.execute { @load_balancing_policy.plan(@keyspace, VOID_STATEMENT) }
        f = f.flat_map {|plan| send_request_by_plan(request, plan, timeout)}
        f.map do |r|
          Statements::Prepared.new(cql, r.metadata, r.result_metadata)
        end
      end

      def execute(statement, options = {})
        f = @reactor.execute { @load_balancing_policy.plan(@keyspace, statement) }
        f.flat_map {|plan| execute_by_plan(statement, plan, options)}
      end

      def batch(statement, options = {})
        f = @reactor.execute { @load_balancing_policy.plan(@keyspace, statement) }
        f.flat_map {|plan| batch_by_plan(statement, plan, options)}
      end

      private


      NO_CONNECTIONS = Future.resolved([])
      BATCH_TYPES    = {
        :logged   => Protocol::BatchRequest::LOGGED_TYPE,
        :unlogged => Protocol::BatchRequest::UNLOGGED_TYPE,
        :counter  => Protocol::BatchRequest::COUNTER_TYPE,
      }.freeze
      CLIENT_CLOSED = Future.failed(ClientError.new('Cannot connect a closed client'))

      def close_connections
        Future.all(*@connections.values.flat_map {|m| m.snapshot.map {|c| c.close}}).map(self)
      end

      def execute_by_plan(statement, plan, options, errors = {})
        host            = plan.next
        timeout         = options[:timeout]
        id              = @prepared_statements[host][statement.cql]
        result_metadata = statement.result_metadata

        if id
          request = Protocol::ExecuteRequest.new(id, statement.params_metadata, statement.params, result_metadata.nil?, options[:consistency], options[:serial_consistency], options[:page_size], options[:paging_state], options[:trace])
          f = send_request(request, timeout, host, result_metadata)
        else
          f = send_request(Protocol::PrepareRequest.new(statement.cql, false), timeout, host)
          f = f.flat_map do |result|
            request = Protocol::ExecuteRequest.new(result.id, statement.params_metadata, statement.params, result_metadata.nil?, options[:consistency], options[:serial_consistency], options[:page_size], options[:paging_state], options[:trace])
            send_request(request, timeout, host, result_metadata)
          end
        end

        f.fallback do |e|
          raise e if e.is_a?(QueryError)

          errors[host] = e
          execute_by_plan(statement, plan, options, errors)
        end
      rescue ::KeyError
        retry
      rescue ::StopIteration
        raise NoHostsAvailable.new(errors)
      end

      def batch_by_plan(batch, plan, options, errors = {})
        host    = plan.next
        request = Protocol::BatchRequest.new(BATCH_TYPES[batch.type], options[:consistency], options[:trace])
        timeout = options[:timeout]

        unprepared = Hash.new {|hash, cql| hash[cql] = []}

        batch.statements.each do |statement|
          cql = statement.cql

          if statement.is_a?(Statements::Bound)
            id = @prepared_statements[host][cql]

            if id
              request.add_prepared(id, statement.params_metadata, statement.params)
            else
              unprepared[cql] << statement
            end
          else
            request.add_query(cql, statement.params)
          end
        end

        if unprepared.empty?
          f = send_request(request, timeout, host)
        else
          to_prepare = unprepared.to_a
          futures    = to_prepare.map do |cql, _|
            send_request(Protocol::PrepareRequest.new(cql, false), timeout, host)
          end

          f = Future.all(*futures).flat_map do |responses|
            to_prepare.each_with_index do |(_, statements), i|
              id = responses[i].id
              statements.each do |statement|
                request.add_prepared(id, statement.params_metadata, statement.params)
              end
            end

            send_request(request, timeout, host)
          end
        end

        f.fallback do |e|
          raise e if e.is_a?(QueryError)

          p e

          errors[host] = e
          batch_by_plan(batch, plan, options, errors)
        end
      rescue ::KeyError
        retry
      rescue ::StopIteration
        raise NoHostsAvailable.new(errors)
      end

      def create_cluster_connector
        authentication_step = @driver.protocol_version == 1 ? Cql::Client::CredentialsAuthenticationStep.new(@driver.credentials) : Cql::Client::SaslAuthenticationStep.new(@driver.auth_provider)
        protocol_handler_factory = lambda { |connection| Protocol::CqlProtocolHandler.new(connection, @reactor, @driver.protocol_version, @driver.compressor) }
        Cql::Client::ClusterConnector.new(
          Cql::Client::Connector.new([
            Cql::Client::ConnectStep.new(@reactor, protocol_handler_factory, @driver.port, @driver.connection_timeout, @logger),
            Cql::Client::CacheOptionsStep.new,
            Cql::Client::InitializeStep.new(@driver.compressor, @logger),
            authentication_step,
            Cql::Client::CachePropertiesStep.new,
          ]),
          @logger
        )
      end

      def connect_to_host_maybe_retry(host, distance)
        f = connect_to_host(host, distance)
        f.fallback do |e|
          raise e unless e.is_a?(Io::ConnectionError)

          connect_to_host_with_retry(host, distance, @reconnection_policy.schedule)
        end
      end

      def connect_to_host_with_retry(host, distance, schedule)
        f = @reactor.schedule_timer(schedule.next)
        f.flat_map do
          if @connecting_hosts.include?(host)
            connect_to_host(host, distance).fallback do |e|
              raise e unless e.is_a?(Io::ConnectionError)

              connect_to_host_with_retry(host, distance, schedule)
            end
          else
            NO_CONNECTIONS
          end
        end
      rescue ::StopIteration
        @connecting_hosts.delete(host)
        NO_CONNECTIONS
      end

      def connect_to_host(host, distance)
        return NO_CONNECTIONS if distance.ignore?

        if distance.local?
          pool_size = @connections_per_local_node
        else
          pool_size = @connections_per_remote_node
        end

        f = create_cluster_connector.connect_all([host.ip.to_s], pool_size)
        f.map do |connections|
          @connecting_hosts.delete(host)
          @connections[host].add_connections(connections)
          @prepared_statements[host] = {}
          connections
        end
      end

      def send_request_by_plan(request, plan, timeout, errors = {})
        host = plan.next
        f = send_request(request, timeout, host)
        f.fallback do |e|
          raise e if e.is_a?(QueryError)

          errors[host] = e
          send_request_by_plan(request, plan, timeout, errors)
        end
      rescue ::KeyError
        retry
      rescue ::StopIteration
        raise NoHostsAvailable.new(errors)
      end

      def send_request(request, timeout, host, raw_metadata = nil)
        connection = @connections.fetch(host).random_connection

        if @keyspace && connection.keyspace != @keyspace
          if connection[:pending_keyspace] == @keyspace
            connection[:pending_switch].flat_map do
              do_send_request(host, connection, request, timeout, raw_metadata)
            end
          else
            f = switch_keyspace(host, connection, timeout)

            connection[:pending_switch] = f

            f.flat_map do
              do_send_request(host, connection, request, timeout, raw_metadata)
            end
          end
        else
          do_send_request(host, connection, request, timeout, raw_metadata)
        end
      end

      def switch_keyspace(host, connection, timeout)
        connection[:pending_keyspace] = @keyspace
        request = Protocol::QueryRequest.new("USE #{@keyspace}", nil, nil, :one)
        do_send_request(host, connection, request, timeout, nil)
      end

      def do_send_request(host, connection, request, timeout, raw_metadata)
        connection.send_request(request, timeout).map do |r|
          case r
          when Protocol::RawRowsResultResponse
            Cql::Client::LazyQueryResult.new(raw_metadata, r, r.trace_id, r.paging_state)
          when Protocol::RowsResultResponse
            Cql::Client::QueryResult.new(r.metadata, r.rows, r.trace_id, r.paging_state)
          when Protocol::VoidResultResponse
            r.trace_id ? Cql::Client::VoidResult.new(r.trace_id) : Cql::Client::VoidResult::INSTANCE
          when Protocol::ErrorResponse
            cql = request.is_a?(Protocol::QueryRequest) ? request.cql : nil
            details = r.respond_to?(:details) ? r.details : nil
            raise QueryError.new(r.code, r.message, cql, details)
          when Protocol::SetKeyspaceResultResponse
            connection[:pending_switch]   = nil
            connection[:pending_keyspace] = nil
            @keyspace = r.keyspace
            nil
          when Protocol::PreparedResultResponse
            @prepared_statements[host][request.cql] = r.id
            r
          else
            nil
          end
        end
      end
    end
  end
end