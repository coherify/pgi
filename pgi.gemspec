lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pgi/version"

Gem::Specification.new do |gem|
  gem.name          = "pgi"
  gem.version       = PGI::VERSION
  gem.authors       = ["Coherify"]
  gem.email         = ["hello@coherify.net"]
  gem.description   = "Simple and convenient interface for PostgreSQL with a few enhancements"
  gem.summary       = "Simple and convenient interface for PostgreSQL with a few enhancements"
  gem.homepage      = "https://github.com/coherify/pgi"
  gem.license       = "MIT"

  gem.required_ruby_version = ">= 3.4.0"

  gem.executables   = gem.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  gem.require_paths = ["lib"]
  gem.files         = Dir["lib/**/*", "CHANGELOG.md", "LICENSE", "README.md", "VERSION", "pgi.gemspec"]

  gem.add_dependency "connection_pool", "~> 2.4"
  gem.add_dependency "pg", "~> 1.5"

  gem.metadata["rubygems_mfa_required"] = "true"
  gem.metadata["source_code_uri"]       = "https://github.com/coherify/pgi"
  gem.metadata["changelog_uri"]         = "https://github.com/coherify/pgi/blob/main/CHANGELOG.md"
end
