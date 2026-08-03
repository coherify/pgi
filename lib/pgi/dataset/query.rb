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
      TABLE_NAME = /\A[a-z_][a-z0-9_]*\z/

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
        @joins       = []
        @join_tables = []
      end

      # Adds an INNER JOIN so WHERE/ORDER BY/keyset can reference the joined
      # table's columns. Joins are for filtering and sorting, not projection:
      # the select list stays the base table's columns, so result rows map to
      # the base model unchanged. Identifiers only - never parameterized.
      #
      # Notes:
      # - a Dataset :scope with unqualified columns becomes ambiguous once a
      #   join shares a column name - qualify scope columns to combine them
      # - keyset pagination over a joined sort column requires at most one
      #   joined row per base row (e.g. FK -> PK); with 1:N joins page
      #   boundaries are ill-defined and the cursor lookup will fail
      #
      # @param table [Symbol] the table to join
      # @param on [Hash] base-table column(s) => joined-table column(s)
      # @raise [RuntimeError] if the table name or on-mapping is invalid
      # @return [Query] return the Query instance (for method chaining)
      def join(table, on:)
        raise "Invalid JOIN table: #{table.inspect}" unless table.to_s.match?(TABLE_NAME)
        raise "JOIN on: must map base column(s) to joined column(s)" unless on.is_a?(Hash) && !on.empty?

        conditions = on.map do |base_col, joined_col|
          "#{Utils.sanitize_column(base_col, @table)} = #{Utils.sanitize_column(joined_col, table)}"
        end.join(" AND ")

        @join_tables << table.to_sym
        @joins << %(INNER JOIN "#{table}" ON #{conditions})
        self
      end

      # Adds a WHERE clause to the query - can only be called once per query,
      # so combine all conditions in a single call
      #
      # @param clause [Hash, String] a Hash of table columns and values - or a string with placeholders
      # @param params [Array] list of values for placeholder substitution
      # @raise [RuntimeError] if a WHERE clause is already set
      # @return [Query] return the Query instance (for method chaining)
      def where(clause = nil, params = [])
        return self unless clause
        return self if clause.empty?

        raise "WHERE clause already set - combine conditions in a single call" if @where

        case clause
        when Hash
          # A Hash value under a table-name key qualifies its columns with that
          # table: where(account_id: 1, users: { name: "x" }). The key must be
          # the base table or a joined table - never guessed - which fences the
          # namespace for possible future non-table Hash semantics (e.g. JSONB).
          clause = clause.flat_map do |k, v|
            if v.is_a?(Hash)
              assert_known_table!(k)
              v.map do |col, val|
                @params << val
                "#{Utils.sanitize_column(col, k)} = $#{@params.size}"
              end
            else
              @params << v
              ["#{Utils.sanitize_column(k, @table)} = $#{@params.size}"]
            end
          end.join(" AND ")
        when String
          raise "Use placeholders in WHERE clause" if clause =~ /=(?!\s*[?$])/

          offset = @params.size
          @params += params
          clause = clause.gsub(/([=<>]{1}\s{0,})(\?)/).with_index { |_, i| "#{Regexp.last_match(1)}$#{offset + i + 1}" }
        else
          raise "WHERE clause can either be a Hash or a String"
        end

        @where = clause

        self
      end

      # Adds a ORDER BY clause to the query - suports multiple calls to the method
      #
      # @param column [Symbol, Hash] the column - a single-pair Hash qualifies
      #   it with a joined table: { users: :name }
      # @param direction [Symbol] the direction the sort should take - can be either `:desc` or `:asc`
      # @raise [RuntimeError] if the direction param is invalid
      # @return [Query] return the Query instance (for method chaining)
      def order(column, direction = :asc)
        raise "Invalid ORDER BY direction: #{direction.inspect}" unless %i[asc desc].include?(direction)

        @order[[qualified_column(column)]] = direction.to_s.upcase
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

      # Apply keyset pagination: orders by (sort_by, id) and, when a cursor id is
      # given, seeks past that row. A nil cursor_id is the first page. The cursor
      # predicate combines with any existing WHERE clause, so call it after #where.
      # For sort_by == :id:    WHERE id > $cursor_id
      # For sort_by != :id:    WHERE (sort_col, id) > (SELECT sort_col, id FROM table WHERE id = $cursor_id)
      # Do not combine with a conflicting #order call — pages are only correct when
      # the leading sort columns match the cursor predicate.
      #
      # @param sort_by [Symbol] the sort column
      # @param cursor_id [*, nil] id of the last row from the previous page, or nil for the first page
      # @param sort_dir [Symbol] :asc or :desc
      # @return [Query] return the Query instance (for method chaining)
      def keyset(sort_by, cursor_id, sort_dir)
        sort_on_id = !sort_by.is_a?(Hash) && sort_by.to_sym == :id
        order(sort_by, sort_dir)
        order(:id, sort_dir) unless sort_on_id
        return self unless cursor_id

        op     = sort_dir == :asc ? ">" : "<"
        id_col = Utils.sanitize_column(:id, @table)
        @params << cursor_id

        clause =
          if sort_on_id
            "#{id_col} #{op} $#{@params.size}"
          else
            # The cursor row's sort value must be resolved through the same
            # FROM (incl. joins) as the outer query, or a joined sort column
            # would not exist in the subselect.
            sort_col = qualified_column(sort_by)
            from     = ["FROM #{@table}", *@joins].join(" ")
            "(#{sort_col}, #{id_col}) #{op} (SELECT #{sort_col}, #{id_col} #{from} WHERE #{id_col} = $#{@params.size})"
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
        if @joins.any? && command.start_with?("SELECT")
          # Joins are filter/sort-only: qualify the default star so joined
          # columns never leak into result rows (and never collide).
          command = %(SELECT "#{@table}".* FROM #{@table}) if command == "SELECT * FROM #{@table}"
          command << " #{@joins.join(" ")}"
        end
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

      private

      # Sanitize a column reference: a bare column qualifies with the base
      # table; a single-pair Hash ({ users: :name }) qualifies with that table,
      # which must be the base table or a joined table.
      #
      # @param column [Symbol, Hash] column or { table => column }
      # @raise [RuntimeError] if the Hash form is malformed or names an unknown table
      # @return [String] sanitized, qualified column
      def qualified_column(column)
        return Utils.sanitize_column(column, @table) unless column.is_a?(Hash)

        raise "Qualified column must be a single { table => column } pair" unless column.size == 1

        table, col = column.first
        assert_known_table!(table)
        Utils.sanitize_column(col, table)
      end

      def assert_known_table!(table)
        return if table.to_sym == @table.to_sym || @join_tables.include?(table.to_sym)

        raise "Unknown table #{table.inspect} - qualify only the base table or joined tables"
      end
    end
  end
end
