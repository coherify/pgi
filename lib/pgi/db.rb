require "pg"
require "connection_pool"
require "pgi/connection"

module PGI
  class DB
    attr_reader :pool

    # Create instance
    #
    # @param pool [ConnectionPool]
    # @param logger [Logger]
    # @param max_retries [Integer]
    def initialize(pool, logger, max_retries: 10)
      @pool        = pool
      @logger      = logger
      @max_retries = max_retries
    end

    def self.configure
      @options = Struct.new(
        :pool_size, :pool_timeout, :pg_conn_uri, :logger
      ).new

      yield @options

      pool = ConnectionPool.new(size: @options.pool_size, timeout: @options.pool_timeout) do
        Connection.new(conn_uri: @options.pg_conn_uri, logger: @options.logger)
      end

      new(pool, @options.logger)
    end

    # wrapper around ConnectionPool#with with auto-healing capabilities
    #
    # @yield PGI:Connection
    def transaction
      raise "Missing block" unless block_given?

      with do |conn|
        conn.transaction do |trans_conn|
          yield Connection.new(conn: trans_conn, logger: @logger)
        end
      end
    end

    # wrapper around ConnectionPool#with with auto-healing capabilities
    #
    # @yield PGI:Connection
    def with
      raise "Missing block" unless block_given?

      retries = 0
      begin
        @pool.with do |conn| # rubocop:disable Style/ExplicitBlockArgument
          yield conn
        end
      rescue PG::ConnectionBad, PG::UnableToSend => e
        if retries >= @max_retries
          @logger.thrown("DB connection was lost - unable to reconnect", e)
          raise
        end
        retries += 1
        @logger.thrown("DB connection was lost - reconnecting(#{retries}/#{@max_retries}) and retrying", e)
        @pool.reload(&:close)
        sleep 2
        retry
      rescue ConnectionPool::TimeoutError => e
        @logger.thrown("Timeout in checking out DB connection from pool - retrying", e)
        retry
      end
    end

    def exec(sql)
      with do |conn|
        conn.exec(sql)
      end
    end

    # Pass the remainder of methods on to a PGI::Connection
    #
    # @See https://deveiate.org/code/pg/PG/Connection.html
    def method_missing(name, ...)
      with do |conn|
        conn.__send__(name, ...)
      end
    end

    def respond_to_missing?(name, include_private = false)
      PG::Connection.method_defined?(name) || super
    end
  end
end
