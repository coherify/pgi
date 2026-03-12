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

        def thrown(msg, exception)
          parts = [
            msg,
            "\t#{exception.class}: #{exception.message}",
            "\tTrace:",
            exception.backtrace.map { |trace_line| "\t\t#{trace_line}" }
          ]

          if (inner = exception.cause)
            parts << "\tCause:"
            parts << "\t\t#{inner.class}: #{inner.message}"
          end

          error(parts.join("\n"))
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
