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
        @cursor    = options.fetch(:cursor, [:id, 0, :asc])
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
      # @see Query#limit for setting a page size
      # @param column [Symbol] the column to use for pagination (default: `:id`). Disable cursor with .cursor(nil)
      # @param offset [*] the row offset for pagination - cannot be nil if column is not nil
      # @param direction [Symbol] the direction the sort should take - can be either `:desc` or `:asc`
      # @return [Query] return the Query instance (for method chaining)
      def cursor(column, offset = nil, direction = :asc)
        @cursor =
          if column.nil?
            nil
          else
            raise "offset cannot be nil" unless offset
            raise "Invalid column name: #{column}" unless Utils.valid_column?(column)
            raise "Invalid direction: #{direction}" unless %i[asc desc].include?(direction)

            [column, offset, direction]
          end
        self
      end

      # Get the Query SQL string prepared for execution
      #
      # @return [String] Query as a SQL string
      def sql
        clause =
          if @cursor
            # Append order by cursor
            order(@cursor[0], @cursor[2])
            cursor_dir = @cursor[2] == :asc ? ">" : "<"

            if @where
              "#{Utils.sanitize_columns(@cursor[0], @table).first} #{cursor_dir} $#{@params.size + 1} AND (#{@where})"
            else
              "#{Utils.sanitize_columns(@cursor[0], @table).first} #{cursor_dir} $#{@params.size + 1}"
            end
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
        ((cur = @cursor&.flatten) && (@params + [cur[1]])) || @params
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
      def each(&block)
        @database
          .exec_stmt(Utils.stmt_name(@table, sql), sql, params)
          .each(&block)
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
      alias_method :inspect, :to_s
    end
  end
end
