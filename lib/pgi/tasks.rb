require "rake"

module PGI
  # Rake tasks for one SchemaMigrator: `PGI::Tasks.install(migrator)` defines
  # db:version, db:migrate, db:rollback, db:destroy and db:seed against it.
  module Tasks
    extend Rake::DSL

    def self.install(migrator)
      namespace :db do
        desc "Prints current schema version"
        task :version do
          puts "Schema Version: #{migrator.current_version}"
        end

        desc "Perform migration up to latest migration available"
        task :migrate do
          migrator.migrate!
          Rake::Task["db:version"].execute
        end

        # TODO: Don't rollback to version = 0 by default
        desc "Perform rollback to specified target or full rollback as default"
        task :rollback, [:target] do |_, args|
          args.with_defaults(target: 0)

          if args.target.to_i < migrator.current_version
            puts "WARNING: You are about to rollback migration from version #{migrator.current_version} to #{args.target}"
            5.downto(1) do |i|
              print "\rI'm giving you #{i} seconds to regret and abort", ".. "
              sleep 1
            end
            puts
          end

          migrator.migrate! args[:target].to_i
          Rake::Task["db:version"].execute
        end

        desc "Destroy all tables with and go back to empty DB"
        task :destroy do
          unless %w[development test staging ci].include?(ENV.fetch("RACK_ENV", nil))
            warn "Destroy not allowed for environment #{ENV.fetch("RACK_ENV", nil).inspect}"
            exit 1
          end

          puts "Destroying all tables..."
          migrator.destroy!
        end

        desc "Seed database"
        task :seed do
          puts "Seeding database with test data..."
          migrator.config.seed_files.each { |file| require file }
        end
      end
    end
  end
end
