ENV["RACK_ENV"] = "test"

# Simplecov must be loaded and configured before anything else
require "simplecov"
require "simplecov-console"
SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new(
  [
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::Console
  ]
)
SimpleCov.start do
  add_filter "/vendor/"
  minimum_coverage 100
end

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

require "pry"

module PGI
  module Test
    module Methods
      module_function

      def postgres_connection
        require "pgi"

        PGI::DB.configure do |options|
          options.pool_size = 1
          options.pool_timeout = 0.2
          options.pg_conn_uri = PG_CONN_URI
          options.logger = LOG_CATCHER
        end
      end

      def postgres_migrator(pg_conn)
        require "pgi/schema_migrator"

        PGI::SchemaMigrator.configure do |config|
          config.migration_files = [File.realpath("test/fixtures/migrations.rb")]
          config.pg_conn = pg_conn
        end
      end

      # Mark a test as a todo by skipping it
      def todo
        skip "Not implemented yet"
      end
    end
  end
end

require "test/support/log_catcher"
LOG_CATCHER = PGI::Test::Support::LogCatcher.logger
# The one place the test database's address lives; ENV overrides for CI
PG_CONN_URI = ENV.fetch("PG_CONN_URI", "postgresql://pgi:password@localhost:5434/pgi_test")
PG_CONN = PGI::Test::Methods.postgres_connection
PGI::Test::Methods.postgres_migrator(PG_CONN).migrate!(0)
PGI::Test::Methods.postgres_migrator(PG_CONN).migrate!
