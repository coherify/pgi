require "pg"

module PGI
  class Connection
    class JSONDecoder < PG::SimpleDecoder
      def decode(string, _tuple = nil, _field = nil)
        ::JSON.parse(string, quirks_mode: true, symbolize_names: true)
      end
    end

    # Create instance
    #
    # @param pool [ConnectionPool]
    # @param logger [Logger]
    def initialize(logger:, conn_uri: nil, conn: nil)
      @logger = logger

      @conn = conn || PG::Connection.new(conn_uri).tap do |new_conn|
        regi = PG::BasicTypeRegistry.new.register_default_types

        regi.register_type 0, "uuid", PG::TextEncoder::String, PG::TextDecoder::String
        regi.register_type 0, "json", PG::TextEncoder::JSON, JSONDecoder
        regi.alias_type(0, "jsonb", "json")

        new_conn.type_map_for_results = PG::BasicTypeMapForResults.new(new_conn, registry: regi)
        new_conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(new_conn, registry: regi)
      end || raise("no connection provided")
    end

    # Execute a prepared statement. Statements are auto-created with fallback to exec_params
    #
    # @example
    #   .exec_stmt("users_by_name", "SELECT * FROM users WHERE name = $1", ["joe"])
    #
    # @param stmt_name [String] name of statement, must be unique for the query
    # @param sql [String] SQL query
    # @param params [Array] list of params
    def exec_stmt(stmt_name, sql, params = [])
      if [PG::PQTRANS_ACTIVE, PG::PQTRANS_INTRANS, PG::PQTRANS_INERROR].include?(@conn.transaction_status)
        @logger&.debug "Unable to use statements within a transaction - falling back to #exec_params"
        return @conn.exec_params(sql, params)
      end

      begin
        @conn.exec_prepared(stmt_name, params)
      rescue PG::InvalidSqlStatementName
        @logger&.debug "Creating missing prepared statement: \"#{stmt_name}\""
        begin
          @conn.prepare(stmt_name, sql) && retry
        rescue PG::SyntaxError => e
          @logger&.error(e)
          raise
        end
      end
    end

    # Pass the remainder of methods on to a PG::Connection
    #
    # @See https://deveiate.org/code/pg/PG/Connection.html
    def method_missing(name, ...)
      @conn.__send__(name, ...)
    end
  end
end
