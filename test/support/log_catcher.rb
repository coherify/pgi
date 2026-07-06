require "logger"
require "stringio"

# :nocov:
module PGI
  module Test
    module Support
      class LogCatcher < Logger
        private_class_method :new

        attr_reader :device
        attr_accessor :facility

        def initialize(device)
          @device = device
          super(@device)
        end

        def run
          device.truncate 0
          yield self
          device.rewind && device.read
        end

        class << self
          def logger
            new(StringIO.new)
          end

          def run(&)
            logger.run(&)
          end
        end
      end
    end
  end
end
# :nocov:
