require "pgi/dataset/utils"

module PGI
  module Dataset
    class Parameters
      Param = Struct.new(:key, :column, :index, :value, keyword_init: true)
      attr_reader :attributes

      def initialize(attributes, table: nil)
        attributes = attributes.to_a.map do |k, v|
          { key: k, column: Utils.sanitize_column(k, table), value: v }
        end
        attributes = attributes.sort_by { |x, _| x[:key] }
        @attributes = attributes.map.with_index do |v, i|
          Param.new(**v, index: "$#{i + 1}")
        end
      end

      %i[key column index value].each do |field|
        define_method(:"by_#{field}") do
          @by_field ||= {}
          @by_field[field] ||= @attributes.to_h { |x| [x[field], x] }
        end

        define_method(:"#{field}s") do
          @all_of_field ||= {}
          @all_of_field[field] ||= @attributes.map { |x| x[field] }
        end
      end

      alias indices indexs
      def length
        attributes.length
      end
    end
  end
end
