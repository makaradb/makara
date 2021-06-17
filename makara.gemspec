require File.expand_path('../lib/makara/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Mike Nelson"]
  gem.email         = ["mike@mikeonrails.com"]
  gem.description   = %q{Read-write split your DB yo}
  gem.summary       = %q{Read-write split your DB yo}
  gem.homepage      = "https://github.com/instacart/makara"
  gem.licenses      = ['MIT']
  gem.metadata      = {
    "source_code_uri" => 'https://github.com/instacart/makara'
  }

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "makara"
  gem.require_paths = ["lib"]
  gem.version       = Makara::VERSION

  gem.required_ruby_version = ">= 2.5.0"

  gem.add_dependency "activerecord", ">= 5.2.0"

  gem.add_development_dependency "rack"
  gem.add_development_dependency "rake", "~> 13.0"
  gem.add_development_dependency "rspec", "~> 3.9"
  gem.add_development_dependency "timecop"
  gem.add_development_dependency "rubocop", "~> 1.17.0"

  if RUBY_ENGINE == "jruby"
    gem.add_development_dependency "activerecord-jdbcmysql-adapter"
    gem.add_development_dependency "activerecord-jdbcpostgresql-adapter"
    gem.add_development_dependency "ruby-debug"
  else
    gem.add_development_dependency "activerecord-postgis-adapter"
    gem.add_development_dependency "pry-byebug"
    gem.add_development_dependency "mysql2"
    gem.add_development_dependency "pg"
  end
end
