require "digest/md5"

module PGI
  module Dataset
    module Utils
      class << self
        # Get a unique statement name for the Query
        #
        # @param table [String] table name
        # @param sql [String] SQL query
        # @return [String] a statement name
        def stmt_name(table, sql)
          "#{table}_#{Digest::MD5.hexdigest(sql)}"
        end

        # Get a sanitized column name(s)
        #
        # @param columns [String|Array] the column name(s) to sanitize
        # @param table [Symbol] the table name
        # @return [Array] list of sanitized column names
        def sanitize_columns(columns, table = nil)
          Array(columns).map do |col|
            sanitize_column(col, table)
          end
        end

        # Get a sanitized column name
        #
        # @param columns [String|Array] the column name(s) to sanitize
        # @param table [Symbol] the table name
        # @return [Array] list of sanitized column names
        def sanitize_column(col, table = nil)
          raise "invalid column name: #{col.inspect}" unless valid_column?(col)

          return "*" if col == "*"

          table ? %("#{table}"."#{col}") : %("#{col}")
        end

        # Validates a column name
        #
        # @param columns [Symbol] the column name(s) to sanitize
        # @return [Boolean] true if valid, otherwise false
        def valid_column?(column)
          column.to_s =~ /\*|[a-z0-9_]+/i
        end
      end
    end
  end
end
