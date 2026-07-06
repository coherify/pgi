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
    # @param max_retries [Integer, Float] shared retry budget for lost connections and pool
    #   checkout timeouts - use Float::INFINITY to ride out arbitrarily long outages
    # @param retry_wait [Numeric] seconds to sleep between reconnection attempts
    def initialize(pool, logger, max_retries: 30, retry_wait: 2)
      @pool        = pool
      @logger      = logger
      @max_retries = max_retries
      @retry_wait  = retry_wait
    end

    def self.configure
      @options = Struct.new(
        :pool_size, :pool_timeout, :pg_conn_uri, :logger, :max_retries, :retry_wait
      ).new

      yield @options

      pool = ConnectionPool.new(size: @options.pool_size, timeout: @options.pool_timeout) do
        Connection.new(conn_uri: @options.pg_conn_uri, logger: @options.logger)
      end

      retry_options = { max_retries: @options.max_retries, retry_wait: @options.retry_wait }.compact
      new(pool, @options.logger, **retry_options)
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
    # Lost connections and pool checkout timeouts share the max_retries budget,
    # so a genuinely stuck pool fails loudly instead of waiting forever.
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
        retries += 1
        if retries > @max_retries
          @logger&.error("DB connection was lost - unable to reconnect (#{e.class}: #{e.message})")
          raise
        end
        @logger&.warn("DB connection was lost - reconnecting(#{retries}/#{@max_retries}) and retrying (#{e.class}: #{e.message})")
        @pool.reload(&:close)
        sleep @retry_wait
        retry
      rescue ConnectionPool::TimeoutError => e
        retries += 1
        if retries > @max_retries
          @logger&.error("Timeout in checking out DB connection from pool - giving up (#{e.message})")
          raise
        end
        @logger&.warn("Timeout in checking out DB connection from pool - retrying(#{retries}/#{@max_retries}) (#{e.message})")
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
