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
      # @param options [Hash] hash of options: scope, where, params, limit, order, returning, cursor
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
        raw_cursor = options.fetch(:cursor, { sort_col: :id, sort_val: 0, id_val: nil, dir: :asc })
        @cursor    =
          case raw_cursor
          when Array
            sort_col, sort_val, dir = raw_cursor
            { sort_col: sort_col, sort_val: sort_val, id_val: nil, dir: dir || :asc }
          else
            raw_cursor
          end
      end

      # Adds a WHERE clause to the query
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

          @params += params
          clause.gsub!(/([=<>]{1}\s{0,})(\?)/).with_index { |_, i| "#{Regexp.last_match(1)}$#{i + 1}" }
        else
          raise "WHERE clause can either be a Hash or a String"
        end

        @where = clause

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

      # Set a cursor for keyset pagination
      #
      # For single-column pagination (sort_by == :id):
      #   cursor(:id, last_id)
      # For composite pagination (sort_by != :id):
      #   cursor(:name, last_name_val, last_id, :asc)
      #   Generates: WHERE (sort_col, id) > ($1, $2) ORDER BY sort_col, id
      #
      # Disable with cursor(nil).
      #
      # @param sort_col [Symbol] the sort column. Disable cursor with .cursor(nil)
      # @param sort_val [*] value of sort_col on the last seen row
      # @param id_val [*] value of id on the last seen row (nil for single-column :id cursor)
      # @param direction [Symbol] :asc or :desc
      # @return [Query] return the Query instance (for method chaining)
      def cursor(sort_col, sort_val = nil, id_val = nil, direction = :asc)
        @cursor =
          if sort_col.nil?
            nil
          else
            raise "cursor value cannot be nil" unless sort_val
            raise "Invalid column name: #{sort_col}" unless Utils.valid_column?(sort_col)
            raise "Invalid direction: #{direction}" unless %i[asc desc].include?(direction)

            { sort_col: sort_col, sort_val: sort_val, id_val: id_val, dir: direction }
          end
        self
      end

      # Set a subquery-based composite cursor for keyset pagination when sort_by != :id.
      # Keeps the cursor interface as a scalar id while generating globally-sorted pages:
      #   WHERE (sort_col, id) > (SELECT sort_col, id FROM table WHERE id = $N)
      # Requires a composite index on (sort_col, id) for efficient seeks.
      #
      # @param sort_col [Symbol] the sort column
      # @param cursor_id [*] the id value of the last seen row (scalar)
      # @param direction [Symbol] :asc or :desc
      # @return [Query] return the Query instance (for method chaining)
      def cursor_subquery(sort_col, cursor_id, direction = :asc)
        raise "Invalid column name: #{sort_col}" unless Utils.valid_column?(sort_col)
        raise "Invalid direction: #{direction}" unless %i[asc desc].include?(direction)
        raise "cursor_id cannot be nil" unless cursor_id

        sort_col_key = Utils.sanitize_columns(sort_col, @table)
        sort_col_sql = sort_col_key.first
        id_col_key   = Utils.sanitize_columns(:id, @table)
        id_col_sql   = id_col_key.first
        dir_op       = direction == :asc ? ">" : "<"

        order(sort_col, direction) unless @order.key?(sort_col_key)
        order(:id, direction) unless @order.key?(id_col_key)

        @params << cursor_id
        subq          = "SELECT #{sort_col_sql}, #{id_col_sql} FROM #{@table} WHERE #{id_col_sql} = $#{@params.size}"
        cursor_clause = "(#{sort_col_sql}, #{id_col_sql}) #{dir_op} (#{subq})"
        @cursor       = nil
        @where        = @where ? "#{cursor_clause} AND (#{@where})" : cursor_clause

        self
      end

      # Get the Query SQL string prepared for execution
      #
      # @return [String] Query as a SQL string
      def sql
        clause =
          if @cursor
            dir_op       = @cursor[:dir] == :asc ? ">" : "<"
            sort_col_key = Utils.sanitize_columns(@cursor[:sort_col], @table)
            sort_col_sql = sort_col_key.first

            order(@cursor[:sort_col], @cursor[:dir]) unless @order.key?(sort_col_key)

            cursor_clause =
              if @cursor[:id_val]
                # Composite: (sort_col, id) > ($N, $N+1)
                id_col_key = Utils.sanitize_columns(:id, @table)
                order(:id, @cursor[:dir]) unless @order.key?(id_col_key)
                id_col_sql = id_col_key.first
                "(#{sort_col_sql}, #{id_col_sql}) #{dir_op} ($#{@params.size + 1}, $#{@params.size + 2})"
              else
                # Single column: sort_col > $N
                "#{sort_col_sql} #{dir_op} $#{@params.size + 1}"
              end

            @where ? "#{cursor_clause} AND (#{@where})" : cursor_clause
          else
            @where
          end

        # Simple Scope implementation
        scope = @scope.dup
        scope << " AND " if scope && clause

        command = @command.dup
        command << " WHERE #{scope}#{clause}" if clause || scope
        command << " ORDER BY #{Array(@order).map { |x| x.join(" ") }.join(", ")}" unless @order.empty?
        command << " LIMIT #{@limit}" if @limit
        command << " RETURNING *" if @command =~ /^UPDATE|INSERT|DELETE/
        command
      end

      # Get the params for placeholder substitution
      #
      # @return [Array] params
      def params
        return @params unless @cursor

        vals = [@cursor[:sort_val]]
        vals << @cursor[:id_val] if @cursor[:id_val]
        @params + vals
      end

      # Get the first record in a result set
      #
      # @return [Hash]
      def first
        limit(1).cursor(nil)
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
        limit(1).cursor(nil)&.first&.fetch("count", 0)
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
