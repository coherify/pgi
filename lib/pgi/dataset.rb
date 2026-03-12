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

    # Get number of rows
    #
    # @return [Integer] number of rows in the table
    def count
      Query.new(@database, @table, nil, **@options).count
    end

    # Get a page (keyset pagination)
    #
    # @param cursor [*] the page cursor
    # @param size [Integer] the page size
    # @param sort_by [Symbol] the column to sort by
    # @param sort_dir [Symbol] the direction to sort by
    # @param where [Array] an optional WHERE clause
    # @return [Array] list of Models, Hashes
    def page(cursor = nil, size = 10, sort_by = :id, sort_dir = :asc, *where)
      query = Query.new(@database, @table, nil, **@options)
      query = query.where(*where)
      query = cursor ? query.cursor(sort_by, cursor, sort_dir) : query.cursor(nil).order(sort_by, sort_dir)
      query = query.limit(size)

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
        raise "Invalid table name: #{table}" unless table =~ /[a-z_]+/

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
