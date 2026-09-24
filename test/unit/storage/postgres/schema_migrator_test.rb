require "test/helper"
require "pgi/db"
require "pgi/schema_migrator"

describe PGI::SchemaMigrator do
  include PGI::Test::Methods

  let(:pg_conn) { postgres_connection }
  subject { postgres_migrator(pg_conn) }

  describe "initialize" do
    it "run migration functions" do
      # Reset to a complety empty database
      subject.migrate!(0)
      pg_conn.exec("DROP TABLE schema_migrations")

      assert_silent do
        subject.migrate! # Nil
        _(subject.current_version).must_equal(1)

        temp = pg_conn.exec("SELECT * FROM dataset")
        _(temp).must_be_instance_of PG::Result

        subject.migrate!(0)
        _(subject.current_version).must_equal(0)
      end
    end
  end

  describe "configure" do
    it "keeps its own config and migrations beside a second migrator" do
      other_conn = postgres_connection
      other = PGI::SchemaMigrator.configure do |config|
        config.migration_files = []
        config.pg_conn = other_conn
      end

      _(subject.migrations.keys).must_equal [0, 1]
      _(other.migrations.keys).must_equal [0]
      _(subject.config.pg_conn).must_be_same_as pg_conn
    end
  end

  describe "version" do
    it "raises outside a migration file" do
      e = assert_raises RuntimeError do
        PGI::SchemaMigrator.version(2) { |_| nil }
      end
      _(e.message).must_equal "FATAL: version declared outside a migration file"
    end
  end

  describe "migrate! errors" do
    it "logs a message if same version detected" do
      log = LOG_CATCHER.run do
        subject.migrate!(0)
        subject.migrate!(0) # Run twice to make sure it has 0 first
      end
      _(log).must_match(/INFO -- : No migrations detected.../)
    end

    it "raises exception when version is a string" do
      e = assert_raises RuntimeError do
        subject.migrate!("a")
      end
      _(e.message).must_equal "FATAL: version must be an integer >= 0"
    end

    it "raises exception when version is negative" do
      e = assert_raises RuntimeError do
        subject.migrate!(-9)
      end
      _(e.message).must_equal "FATAL: version must be an integer >= 0"
    end

    it "raises an exception when version doesn't exist" do
      e = assert_raises RuntimeError do
        subject.migrate!(99)
      end
      _(e.message).must_equal "FATAL: Migration version does not exist"
    end
  end
end
