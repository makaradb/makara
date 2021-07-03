require 'openssl'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/hash/except'
require 'cgi'

# Convenience methods to grab subconfigs out of the primary configuration.
# Provides a way to generate a consistent ID based on a unique config.
# Makara configs should be formatted like so:
# --
#   top_level: 'variable'
#   another: 'top level variable'
#   makara:
#     primary_ttl: 3
#     blacklist_duration: 20
#     connections:
#       - role: 'master' # Deprecated in favor of 'primary'
#       - role: 'primary'
#       - role: 'slave' # Deprecated in favor of 'replica'
#       - role: 'replica'
#         name: 'replica2'

module Makara
  class ConfigParser
    DEFAULTS = {
      primary_ttl: 5,
      blacklist_duration: 30,
      sticky: true
    }

    DEPRECATED_KEYS = {
      slave_strategy:       :replica_strategy,
      slave_shard_aware:    :replica_shard_aware,
      slave_default_shard:  :replica_default_shard,
      master_strategy:      :primary_strategy,
      master_shard_aware:   :primary_shard_aware,
      master_default_shard: :primary_default_shard,
      master_ttl:           :primary_ttl
    }.freeze

    ConnectionUrlResolver =
      if ::ActiveRecord::VERSION::STRING >= "6.1.0"
        ::ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver
      else
        ::ActiveRecord::ConnectionAdapters::ConnectionSpecification::ConnectionUrlResolver
      end

    # NOTE: url format must be, e.g.
    # url: mysql2://...
    # NOT
    # url: mysql2_makara://...
    # since the '_' in the protocol (mysql2_makara) makes the URI invalid
    # NOTE: Does not use ENV['DATABASE_URL']
    def self.merge_and_resolve_default_url_config(config)
      if ENV['DATABASE_URL']
        Makara::Logging::Logger.log "Please rename DATABASE_URL to use in the database.yml", :warn
      end
      return config unless config.key?(:url)

      url = config[:url]
      url_config = ConnectionUrlResolver.new(url).to_hash
      url_config = url_config.symbolize_keys
      url_config.delete(:adapter)
      config.delete(:url)
      config.update(url_config)
    end

    attr_reader :makara_config

    def initialize(config)
      @config = config.symbolize_keys
      @makara_config = DEFAULTS.merge(@config[:makara] || {})
      @makara_config = @makara_config.symbolize_keys

      replace_deprecated_keys!

      @id = sanitize_id(@makara_config[:id])
    end

    def id
      @id ||= begin
        sorted = recursive_sort(@config)
        OpenSSL::Digest::SHA256.hexdigest(sorted.to_s)
      end
    end

    def primary_configs
      all_configs
        .select { |config| config[:role] == 'primary' }
        .map { |config| config.except(:role) }
    end

    def master_configs
      warn "#{self.class}#master_configs is deprecated. Switch to #primary_configs"
      primary_configs
    end

    def replica_configs
      all_configs
        .reject { |config| config[:role] == 'primary' }
        .map { |config| config.except(:role) }
    end

    def slave_configs
      warn "#{self.class}#slave_configs is deprecated. Switch to #replica_configs"
      replica_configs
    end

    protected

    def all_configs
      @all_configs ||= @makara_config[:connections].map do |connection|
        config = base_config.merge(makara_config.except(:connections)).merge(connection.symbolize_keys)

        if config[:role] == "master"
          warn "Makara role 'master' is deprecated. Use 'primary' instead"
          config[:role] = "primary"
        end

        if config[:role] == "slave"
          warn "Makara role 'slave' is deprecated. Use 'replica' instead"
          config[:role] = "primary"
        end

        config
      end
    end

    def base_config
      @base_config ||= DEFAULTS.merge(@config).except(:makara)
    end

    def recursive_sort(thing)
      return thing.to_s unless thing.include?(Enumerable)

      thing.map do |part|
        recursive_sort(part)
      end

      thing.sort_by(&:to_s)
    end

    def sanitize_id(id)
      return if id.nil? || id.empty?

      id.gsub(/[\|:]/, '').tap do |sanitized_id|
        if sanitized_id.size != id.size
          Makara::Logging::Logger.log "Proxy id '#{id}' changed to '#{sanitized_id}'", :warn
        end
      end
    end

    def replace_deprecated_keys!
      DEPRECATED_KEYS.each do |key, replacement|
        next unless @makara_config[key]

        warn "Makara config key #{key.inspect} is deprecated, use #{replacement.inspect} instead"

        @makara_config[replacement] = @makara_config.delete(key)
      end
    end
  end
end
