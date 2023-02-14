lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pgi/version"

Gem::Specification.new do |gem|
  gem.name          = "pgi"
  gem.version       = PGI::VERSION
  gem.authors       = ["PGI"]
  gem.email         = ["hello@coherify.net"]
  gem.description   = "Simple and convenient interface for PostgreSQL with a few enhancements"
  gem.summary       = "Simple and convenient interface for PostgreSQL with a few enhancements"
  gem.homepage      = "https://github.com/coherify/pgi"

  gem.required_ruby_version = ">= 3.0.0"

  gem.executables   = gem.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]
  gem.files         = Dir["lib/**/*", ".gitignore", "CHANGELOG.md", "Gemfile", "Rakefile", "README.md", "pgi.gemspec"]

  gem.add_dependency "connection_pool", "~> 2.3.0"
  gem.add_dependency "pg", "~> 1.4.5"

  gem.add_development_dependency "bundler-audit"
  gem.add_development_dependency "minitest"
  gem.add_development_dependency "minitest-reporters"
  gem.add_development_dependency "pry"
  gem.add_development_dependency "rake"
  gem.add_development_dependency "rubocop"
  gem.add_development_dependency "simplecov"
  gem.add_development_dependency "simplecov-console"
end
