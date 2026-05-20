require "pgi/dataset/query"
require "pgi/dataset/utils"
require "pgi/dataset/parameters"

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

    # Insert new row
    #
    # @param args [Hash|Object] row data
    # @return [Model,Hash]
    def insert(**attributes)
      attributes = Utils.strip_uninsertable(attributes)

      insert!(**attributes)
    end

    def insert!(**attributes)
      params = Parameters.new(attributes)
      command = "INSERT INTO #{@table}"
      command <<
        if params.columns.empty?
          " DEFAULT VALUES"
        else
          " (#{params.columns.join(", ")}) VALUES (#{params.indexs.join(", ")}) "
        end

      _to_model Query.new(@database, @table, command, params: params.values).limit(nil).cursor(nil).to_a.first
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
      args[:id] = id
      params = Parameters.new(args)
      set_params = params.attributes.filter { |x| x.key != :id }
      id_param = params.by_key[:id]
      command = "UPDATE #{@table} SET #{set_params.map { |x| "#{x.column} = #{x.index}" }.join(", ")} " \
                "WHERE #{id_param.column} = #{id_param.index} RETURNING *"

      # TODO: Query throws `PG::IndeterminateDatatype: ERROR:  could not determine data type of parameter $2`
      # _to_model Query.new(@database, @table, command, params: params).where(id: id).limit(nil).cursor(nil)

      _to_model @database.exec_stmt(Utils.stmt_name(@table, command), command, params.values)&.first
    end

    # Delete row
    #
    # @param id [*] ID of row
    # @return [Model,Hash]
    def delete(id)
      command = "DELETE FROM #{@table}"
      _to_model Query.new(@database, @table, command, **@options).where(id: id).limit(nil).cursor(nil).to_a.first
    end

    # Get a row by its id
    #
    # @param id [*] ID of row
    # @return [Model,Hash]
    def find(id)
      _to_model Query.new(@database, @table, nil, **@options).where(id: id).cursor(nil).first
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
      _to_model where.order(sort_by.to_sym, :asc).limit(1).cursor(nil).first
    end

    # Get last row by column (default: :id)
    #
    # @return [Model,Hash]
    def last(sort_by = :id)
      _to_model where.order(sort_by.to_sym, :desc).limit(1).cursor(nil).first
    end

    # Declare which columns may be used as sort_by in page().
    # Each listed column must have a composite index on (column, id).
    # :id is always sortable and does not need to be listed.
    # If sortable is never called, any column is accepted (no enforcement).
    #
    # @param columns [Symbol, ...] sortable column names
    def sortable(*columns)
      @sortable_columns = columns.map(&:to_sym)
    end

    # Get number of rows
    #
    # @return [Integer] number of rows in the table
    def count
      Query.new(@database, @table, nil, **@options).count
    end

    # Get a page of results using keyset pagination.
    #
    # The cursor is always the scalar id of the last row from the previous page.
    # Pass nil for the first page. For subsequent pages pass the id value of the
    # last row returned.
    #
    # When sort_by == :id:    WHERE id > $cursor ORDER BY id
    # When sort_by != :id:    WHERE (sort_col, id) > (SELECT sort_col, id FROM table WHERE id = $cursor)
    #                         ORDER BY sort_col, id
    #
    # Requires a composite index on (sort_by, id) for optimal performance.
    #
    # @param cursor [*, nil] id of the last row from the previous page, or nil
    # @param size [Integer] number of rows per page
    # @param sort_by [Symbol] column to sort by
    # @param sort_dir [Symbol] :asc or :desc
    # @param where [Array] optional WHERE clause forwarded to Query#where
    # @return [Array] list of Models or Hashes
    def page(cursor = nil, size = 10, sort_by = :id, sort_dir = :asc, *where)
      if @sortable_columns && sort_by.to_sym != :id && !@sortable_columns.include?(sort_by.to_sym)
        raise "Cannot sort by :#{sort_by} — not declared as sortable. " \
              "Add `sortable :#{sort_by}` and create a composite index (#{sort_by}, id)."
      end

      query = Query.new(@database, @table, nil, **@options).where(*where).limit(size)

      query =
        if cursor
          if sort_by == :id
            query.cursor(:id, cursor, nil, sort_dir)
          else
            query.cursor_subquery(sort_by, cursor, sort_dir)
          end
        else
          q = query.cursor(nil).order(sort_by, sort_dir)
          sort_by == :id ? q : q.order(:id, sort_dir)
        end

      _to_models query.to_a
    end

    private

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
