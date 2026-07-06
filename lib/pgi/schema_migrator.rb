module PGI
  class SchemaMigrator
    @config     = Struct.new(:pg_conn, :migration_files, :seed_files).new
    @migrations = Hash.new { |h, k| h[k] = {} }.merge(
      # Default migration
      0 => {
        1 => "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER," \
             "created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP);",
        -1 => "DROP TABLE schema_migrations;"
      }
    )

    def initialize(version)
      raise "FATAL: version must be an integer > 0" unless version.is_a?(Integer) && version.positive?
      raise "FATAL: Duplication migration version" if self.class.migrations.key?(version)
      raise "FATAL: Broken migration ID sequence" unless version == self.class.migrations.keys.max + 1

      @version = version
    end

    def up
      self.class.migrations[@version][1] = yield
    end

    def down
      self.class.migrations[@version][-1] = yield
    end

    class << self
      attr_reader :config, :migrations

      def configure
        yield(config)

        self
      end

      def migrate!(version = nil)
        raise "FATAL: version must be an integer >= 0" unless version.nil? || (version.is_a?(Integer) && version >= 0)

        config.migration_files.sort.each { |file| require file }

        raise "FATAL: Migration version does not exist" unless version.nil? || migrations.key?(version)

        to_version = version || latest_migration
        current    = current_version

        if current == to_version
          puts "No migrations detected..."
          return
        end

        config.pg_conn.transaction do
          if to_version > current
            ((current + 1)..to_version).each do |v|
              config.pg_conn.exec(migrations[v][1])
              add_version(v)
            end
          else
            current.downto(to_version + 1) do |v|
              delete_version(v)
              config.pg_conn.exec(migrations[v][-1])
            end
          end
        end
      end

      def version(version)
        yield(new(version))
      end

      def current_version
        current = config.pg_conn.exec(<<~SQL).first
          SELECT * FROM schema_migrations
          ORDER BY version DESC LIMIT 1
        SQL

        (current && current["version"].to_i) || 0
      rescue PG::UndefinedTable => e
        raise unless e.message =~ /relation "schema_migrations" does not exist/

        -1
      end

      def destroy!
        config.pg_conn.exec(<<~SQL)
          DO $$ DECLARE
            r RECORD;
          BEGIN
            FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = current_schema()) LOOP
              EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
            END LOOP;
            FOR r IN (SELECT DISTINCT typname FROM pg_type INNER JOIN pg_enum ON pg_enum.enumtypid = pg_type.oid) LOOP
              EXECUTE 'DROP TYPE IF EXISTS ' || quote_ident(r.typname) || ' CASCADE';
            END LOOP;
          END $$;
        SQL
      end

      private

      def latest_migration
        migrations.keys.max || -1
      end

      def add_version(version)
        config.pg_conn.exec_params(<<~SQL, [version])
          INSERT INTO schema_migrations
          (version) VALUES ($1)
        SQL
      end

      def delete_version(version)
        config.pg_conn.exec_params(<<~SQL, [version])
          DELETE FROM schema_migrations
          WHERE version = $1
        SQL
      end
    end
  end
end
