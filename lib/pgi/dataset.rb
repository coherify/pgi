require "pgi/dataset/query"
require "pgi/dataset/utils"

module PGI
  module Dataset
    # Select specific columns
    #
    # @param args [String|Array] list of columns to include in result set
    # @return [Query]
    def select(*args)
      columns = args.empty? ? "*" : Utils.sanitize_columns(args, @table).join(", ")
      command = "SELECT #{columns} FROM #{@table}"
      Query.new(@database, @table, command, **@options)
    end

    # Select specfic rows
    #
    # @param args [String|Array] conditions to search for
    # @return [Query]
    def where(*)
      Query.new(@database, @table, nil, **@options).where(*)
    end

    # Start a query with an INNER JOIN so WHERE/ORDER BY can reference the
    # joined table's columns (filtering and sorting only - result rows stay
    # base-table rows). Like #where, the returned Query yields raw row hashes;
    # model mapping is the privilege of Dataset methods - for a paginated,
    # model-mapped joined read use #page with the joins: keyword.
    #
    # @param table [Symbol] the table to join
    # @param on [Hash] base-table column(s) => joined-table column(s)
    # @return [Query]
    def join(table, on:, type: :inner)
      Query.new(@database, @table, nil, **@options).join(table, on: on, type: type)
    end

    # Start a query with a case-insensitive substring search across the given
    # columns (see Query#search). Like #where/#join the returned Query yields
    # raw row hashes; for a paginated, model-mapped search use #page with the
    # search: keyword.
    #
    # @param columns [Array] the text columns to match against
    # @param terms [Array<String>] search terms, already tokenised by the caller
    # @return [Query]
    def search(columns, terms)
      Query.new(@database, @table, nil, **@options).search(columns, terms)
    end

    # Insert new row
    #
    # @param args [Hash|Object] row data
    # @return [Model,Hash]
    def insert(**attributes)
      attributes = Utils.strip_uninsertable(attributes)

      insert!(**attributes)
    end

    def insert!(**attributes)
      columns, placeholders, values = sql_params(attributes)
      command = "INSERT INTO #{@table}"
      command <<
        if columns.empty?
          " DEFAULT VALUES"
        else
          " (#{columns.join(", ")}) VALUES (#{placeholders.join(", ")}) "
        end

      _to_model Query.new(@database, @table, command, params: values).limit(nil).to_a.first
    end

    # Update row
    #
    # @param id [*] ID of row
    # @param args [Hash] data for update
    # @return [Model,Hash]
    def update(id, **args)
      args = Utils.strip_unupdateable(args)

      update!(id, **args)
    end

    def update!(id, **args)
      columns, placeholders, values = sql_params(args)
      set_clause = columns.zip(placeholders).map { |c, p| "#{c} = #{p}" }.join(", ")
      command = "UPDATE #{@table} SET #{set_clause} " \
                "WHERE #{Utils.sanitize_column(:id)} = $#{values.size + 1} RETURNING *"

      # TODO: Query throws `PG::IndeterminateDatatype: ERROR:  could not determine data type of parameter $2`
      # _to_model Query.new(@database, @table, command, params: values + [id]).where(id: id).limit(nil)

      _to_model @database.exec_stmt(Utils.stmt_name(@table, command), command, values + [id])&.first
    end

    # Delete row
    #
    # @param id [*] ID of row
    # @return [Model,Hash]
    def delete(id)
      command = "DELETE FROM #{@table}"
      _to_model Query.new(@database, @table, command, **@options).where(id: id).limit(nil).to_a.first
    end

    # Get a row by its id
    #
    # @param id [*] ID of row
    # @return [Model,Hash]
    def find(id)
      _to_model Query.new(@database, @table, nil, **@options).where(id: id).first
    end

    # Get all rows
    #
    # @return [Array] list of Models, Hashes
    def all
      _to_models Query.new(@database, @table, nil, **@options).limit(nil).to_a
    end

    # Get first row by column (default: :id)
    #
    # @return [Model,Hash]
    def first(sort_by = :id)
      _to_model where.order(sort_by.to_sym, :asc).first
    end

    # Get last row by column (default: :id)
    #
    # @return [Model,Hash]
    def last(sort_by = :id)
      _to_model where.order(sort_by.to_sym, :desc).first
    end

    # Get number of rows
    #
    # @return [Integer] number of rows in the table
    def count
      Query.new(@database, @table, nil, **@options).count
    end

    # Get a page of results using keyset pagination.
    #
    # Sorting by a column other than :id requires a composite index on
    # (sort_by, id) for seek performance — see README.
    #
    # @param cursor [*, nil] id of the last row from the previous page, or nil for the first page
    # @param size [Integer] number of rows per page
    # @param sort_by [Symbol] column to sort by
    # @param sort_dir [Symbol] :asc or :desc
    # Joins (filter/sort only - result rows stay base-table rows) are passed
    # as data: joins: { users: { user_id: :id } } maps joined table => on
    # mapping, enabling qualified where ({ users: { name: "x" } }) and a
    # qualified sort_by ({ users: :name }). Keyset over a joined sort column
    # requires at most one joined row per base row (e.g. FK -> PK). An on-key
    # may itself be qualified ({ { memberships: :user_id } => :id }) to chain a
    # second hop off an earlier join; declare the joins in dependency order (an
    # ordered Hash preserves it).
    #
    # @param where [Array] optional WHERE clause forwarded to Query#where
    # @param joins [Hash] joined table => on-mapping, forwarded to Query#join
    # @param search [Hash, nil] { columns:, terms: } forwarded to Query#search -
    #   a substring search AND'ed into the WHERE, keyset-compatible (it only
    #   adds a predicate; the cursor stays on the sort column). Columns may be
    #   qualified with a joined table, so a search can span the same joins.
    # @param collate [String, nil] collation for the sort column (e.g.
    #   "da-x-icu"), forwarded to Query#keyset
    # @return [Array] list of Models or Hashes
    def page(cursor = nil, size = 10, sort_by = :id, sort_dir = :asc, *where, joins: {}, search: nil, collate: nil)
      query = Query.new(@database, @table, nil, **@options)
      joins.each { |table, on| query.join(table, on: on) }
      query.where(*where)
      query.search(search[:columns], search[:terms]) if search

      _to_models query.limit(size).keyset(sort_by, cursor, sort_dir, collate: collate).to_a
    end

    private

    # Build aligned column names, $N placeholders and values from an attributes
    # hash. Sorted by key so identical attributes always produce identical SQL -
    # the prepared-statement name is a digest of the SQL.
    #
    # @param attributes [Hash] column => value
    # @return [Array(Array, Array, Array)] sanitized columns, placeholders, values
    def sql_params(attributes)
      attrs = attributes.sort.to_h
      [Utils.sanitize_columns(attrs.keys), (1..attrs.size).map { |i| "$#{i}" }, attrs.values]
    end

    # Call #to_model on super class if defined
    #
    # @param obj [Hash]
    # @return [Model, Hash] Model instance or a Hash
    def _to_model(obj)
      respond_to?(:to_model) ? obj && to_model(obj) : obj
    end

    # Call #to_models on super class if defined
    #
    # @param obj [Array]
    # @return [Array] list of Model instance or a Hashes
    def _to_models(obj)
      respond_to?(:to_models) ? obj && to_models(obj) : obj
    end

    class << self
      def [](database, table, **options)
        raise "Invalid table name: #{table}" unless table.to_s =~ /\A[a-z_][a-z0-9_]*\z/

        mod = clone
        mod.instance_variable_set("@database", database)
        mod.instance_variable_set("@table", table)
        mod.instance_variable_set("@options", options)
        mod
      end

      def extended(klass)
        raise "Database table not specified" unless @table

        klass.instance_variable_set("@database", @database)
        klass.instance_variable_set("@table", @table)
        klass.instance_variable_set("@options", @options)
      end
    end
    # end Eigen class
  end
end
