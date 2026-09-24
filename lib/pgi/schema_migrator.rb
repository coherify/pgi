module PGI
  # Plain up/down SQL migrations tracked in a `schema_migrations` table.
  #
  # `SchemaMigrator.configure` returns a migrator owning its config and its migration
  # set. Migration files declare `PGI::SchemaMigrator.version(n)`; that call lands in
  # the migrator loading the file, so two migrators never share migrations.
  class SchemaMigrator
    Config = Struct.new(:pg_conn, :migration_files, :seed_files, :logger)

    # Collects one version's SQL; yielded by SchemaMigrator.version
    class Version
      def initialize(sql)
        @sql = sql
      end

      def up
        @sql[1] = yield
      end

      def down
        @sql[-1] = yield
      end
    end

    attr_reader :config

    def self.configure
      config = Config.new
      yield config

      new(config)
    end

    # Declares a migration; only valid inside a file a migrator is loading.
    def self.version(version)
      migrations = Thread.current[:pgi_schema_migrations]
      raise "FATAL: version declared outside a migration file" unless migrations
      raise "FATAL: version must be an integer > 0" unless version.is_a?(Integer) && version.positive?
      raise "FATAL: Duplication migration version" if migrations.key?(version)
      raise "FATAL: Broken migration ID sequence" unless version == migrations.keys.max + 1

      yield Version.new(migrations[version] = {})
    end

    def initialize(config)
      @config = config
    end

    def migrations
      @migrations ||= load_migrations
    end

    def migrate!(version = nil)
      raise "FATAL: version must be an integer >= 0" unless version.nil? || (version.is_a?(Integer) && version >= 0)
      raise "FATAL: Migration version does not exist" unless version.nil? || migrations.key?(version)

      to_version = version || migrations.keys.max
      current    = current_version

      if current == to_version
        config.logger&.info("No migrations detected...")
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

    # `load`, not `require`: each migrator reads the files into its own set.
    def load_migrations
      Thread.current[:pgi_schema_migrations] = {
        0 => {
          1 => "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER," \
               "created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP);",
          -1 => "DROP TABLE schema_migrations;"
        }
      }
      config.migration_files.sort.each { |file| load file }
      Thread.current[:pgi_schema_migrations]
    ensure
      Thread.current[:pgi_schema_migrations] = nil
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
