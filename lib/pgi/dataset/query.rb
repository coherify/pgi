require "digest/md5"
require "pgi/dataset/utils"

module PGI
  module Dataset
    class Query
      # Create instance of Query
      #
      # @param database [PGI::DB] a configured instance of DB
      # @param table [Symbol] the name of the database table to operate on
      # @param command [String] the command part of the query (default: `SELECT * FROM <table>`)
      # @param options [Hash] hash of options: scope, where, params, limit, order, returning
      # @return [Query] new instance of Query
      def initialize(database, table, command, **options)
        @database  = database
        @table     = table
        @command   = command || "SELECT * FROM #{@table}"
        @scope     = options.fetch(:scope, nil)
        @where     = options.fetch(:where, nil)
        @params    = options.fetch(:params, [])
        @order     = options.fetch(:order, {})
        @limit     = options.fetch(:limit, 10)
        @returning = options.fetch(:returning, nil)
      end

      # Adds a WHERE clause to the query - multiple calls are combined with AND
      #
      # @param clause [Hash, String] a Hash of table columns and values - or a string with placeholders
      # @param params [Array] list of values for placeholder substitution
      # @return [Query] return the Query instance (for method chaining)
      def where(clause = nil, params = [])
        return self unless clause
        return self if clause.empty?

        case clause
        when Hash
          clause = clause.map do |k, v|
            @params << v
            "#{Utils.sanitize_columns(k, @table).first} = $#{@params.size}"
          end.join(" AND ")
        when String
          raise "Use placeholders in WHERE clause" if clause =~ /=(?!\s*[?$])/

          offset = @params.size
          @params += params
          clause = clause.gsub(/([=<>]{1}\s{0,})(\?)/).with_index { |_, i| "#{Regexp.last_match(1)}$#{offset + i + 1}" }
        else
          raise "WHERE clause can either be a Hash or a String"
        end

        @where = @where ? "(#{@where}) AND (#{clause})" : clause

        self
      end

      # Adds a ORDER BY clause to the query - suports multiple calls to the method
      #
      # @param column [Symbol] the columns
      # @param direction [Symbol] the direction the sort should take - can be either `:desc` or `:asc`
      # @raise [RuntimeError] if the direction param is invalid
      # @return [Query] return the Query instance (for method chaining)
      def order(column, direction = :asc)
        raise "Invalid ORDER BY direction: #{direction.inspect}" unless %i[asc desc].include?(direction)

        @order[Utils.sanitize_columns(column, @table)] = direction.to_s.upcase
        self
      end

      # Adds a LIMIT clause to the query
      #
      # @param direction [Integer] the direction the sort should take - can be either `:desc` or `:asc`
      # @raise [RuntimeError] if the direction param is invalid
      # @return [Query] return the Query instance (for method chaining)
      def limit(number)
        raise "LIMIT must be an integer or nil" unless number.nil? || number.is_a?(Integer)

        @limit = number
        self
      end

      # Apply a keyset pagination cursor as a WHERE predicate. Combines with any
      # existing WHERE clause, so call it after #where. Does not set ORDER BY —
      # the caller (Dataset#page) orders by (sort_by, id) to match the predicate.
      # For sort_by == :id:    WHERE id > $cursor_id
      # For sort_by != :id:    WHERE (sort_col, id) > (SELECT sort_col, id FROM table WHERE id = $cursor_id)
      #
      # @param sort_by [Symbol] the sort column
      # @param cursor_id [*] id of the last row from the previous page
      # @param sort_dir [Symbol] :asc or :desc
      # @return [Query] return the Query instance (for method chaining)
      def with_cursor(sort_by, cursor_id, sort_dir)
        raise "Invalid direction: #{sort_dir.inspect}" unless %i[asc desc].include?(sort_dir)

        op     = sort_dir == :asc ? ">" : "<"
        id_col = Utils.sanitize_columns(:id, @table).first
        @params << cursor_id

        clause =
          if sort_by.to_sym == :id
            "#{id_col} #{op} $#{@params.size}"
          else
            sort_col = Utils.sanitize_columns(sort_by, @table).first
            "(#{sort_col}, #{id_col}) #{op} (SELECT #{sort_col}, #{id_col} FROM #{@table} WHERE #{id_col} = $#{@params.size})"
          end

        @where = @where ? "#{clause} AND (#{@where})" : clause
        self
      end

      # Get the Query SQL string prepared for execution
      #
      # @return [String] Query as a SQL string
      def sql
        # Simple Scope implementation
        scope = @scope.dup
        scope << " AND " if scope && @where

        command = @command.dup
        command << " WHERE #{scope}#{@where}" if @where || scope
        command << " ORDER BY #{Array(@order).map { |x| x.join(" ") }.join(", ")}" unless @order.empty?
        command << " LIMIT #{@limit}" if @limit
        command << " RETURNING *" if @command =~ /^UPDATE|INSERT|DELETE/
        command
      end

      # Get the params for placeholder substitution
      #
      # @return [Array] params
      attr_reader :params

      # Get the first record in a result set
      #
      # @return [Hash]
      def first
        limit(1)
        @database
          .exec_stmt(Utils.stmt_name(@table, sql), sql, params)
          .first
      end

      # Get all the records in a result set
      #
      # @return [Array] Array of records as Hashes
      def to_a
        @database
          .exec_stmt(Utils.stmt_name(@table, sql), sql, params)
          .to_a
      end

      # Loop through records in a result set
      def each(&)
        @database
          .exec_stmt(Utils.stmt_name(@table, sql), sql, params)
          .each(&)
      end

      # Explain some query
      #
      # @return [String] Formatted string explaining query plan
      def explain
        explain_sql = "EXPLAIN " << sql.dup.tap do |s|
          params.each_with_index do |x, i|
            x =
              case x
              when String
                "'#{x}'"
              else
                x
              end

            s.gsub!("$#{i + 1}", x.to_s)
          end
        end

        @database.exec(explain_sql)&.values&.join("\n")
      end

      # Get the number of records in a result set
      #
      # @return [Integer]
      def count
        @command = "SELECT COUNT(*) FROM #{@table}"
        @order   = {}
        first&.fetch("count", 0)
      end

      # Get a string representation of the instance
      #
      # @return [String]
      def to_s
        "#<PGI::Dataset::Query:#{object_id} @sql=#{sql} @params=#{params}>"
      end
      alias inspect to_s
    end
  end
end
