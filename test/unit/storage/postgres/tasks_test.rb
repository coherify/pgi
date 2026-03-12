require "rake"
require "test/helper"
require "pgi/db"
require "pgi/schema_migrator"

def execute_rake(task, env = "test")
  ENV["RACK_ENV"] = env
  Rake::Task[task].reenable
  Rake.application.invoke_task task
end

describe "tasks.rb" do
  include PGI::Test::Methods

  let(:pg_conn) { postgres_connection }

  before do
    PGI::SchemaMigrator.configure do |config|
      config.migration_files = [File.realpath("test/fixtures/migrations.rb")]
      config.seed_files = []
      config.pg_conn = pg_conn
    end

    Rake.application.rake_require "pgi/tasks"
    Rake::Task.define_task(:environment)
  end

  describe "db:migrate" do
    it "calls migrate! and print out the current verson" do
      execute_rake("db:rollback")
      assert_output("Schema Version: 1\n") do
        execute_rake("db:migrate")
      end
    end
  end

  describe "db:rollback" do
    it "execute a rollback of the version" do
      execute_rake("db:migrate") # Make sure there is something to rollback
      assert_output(
        "WARNING: You are about to rollback migration from version 1 to 0\n" \
        "\rI'm giving you 5 seconds to regret and abort.. " \
        "\rI'm giving you 4 seconds to regret and abort.. " \
        "\rI'm giving you 3 seconds to regret and abort.. " \
        "\rI'm giving you 2 seconds to regret and abort.. " \
        "\rI'm giving you 1 seconds to regret and abort.. \n" \
        "Schema Version: 0\n"
      ) do
        execute_rake("db:rollback")
      end
    end
  end

  describe "db:seed" do
    it "seed database with data" do
      execute_rake("db:migrate") # Make sure there is something to seed
      assert_output("Seeding database with test data...\n") do
        execute_rake("db:seed")
      end
    end
  end

  describe "db:destroy" do
    it "destroy all tables in the database" do
      execute_rake("db:migrate") # Make sure there is something to destroy
      assert_output(
        "Destroying all tables...\n"
      ) do
        execute_rake("db:destroy")
      end
    end

    it "fails to destroy all tables in the database in production" do
      _, err = capture_io do
        e = assert_raises SystemExit do
          execute_rake("db:destroy", "production")
        end
        _(e.status).must_equal 1
      end
      _(err).must_match(/Destroy not allowed for environment "production"/)
    end
  end
end
