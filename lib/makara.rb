require 'active_support'
require 'makara/version'
require 'makara/railtie' if defined?(Rails)
module Makara
  autoload :Cache,              'makara/cache'
  autoload :ConfigParser,       'makara/config_parser'
  autoload :ConnectionWrapper,  'makara/connection_wrapper'
  autoload :Context,            'makara/context'
  autoload :Cookie,             'makara/cookie'
  autoload :ErrorHandler,       'makara/error_handler'
  autoload :Middleware,         'makara/middleware'
  autoload :Pool,               'makara/pool'
  autoload :Proxy,              'makara/proxy'

  module Errors
    autoload :MakaraError,                   'makara/errors/makara_error'
    autoload :AllConnectionsBlocklisted,     'makara/errors/all_connections_blocklisted'
    autoload :BlocklistConnection,           'makara/errors/blocklist_connection'
    autoload :NoConnectionsAvailable,        'makara/errors/no_connections_available'
    autoload :BlocklistedWhileInTransaction, 'makara/errors/blocklisted_while_in_transaction'
    autoload :InvalidShard,                  'makara/errors/invalid_shard'

    DEPRECATED_CLASSES = {
      :AllConnectionsBlacklisted     => AllConnectionsBlocklisted,
      :BlacklistConnection           => BlocklistConnection,
      :BlacklistedWhileInTransaction => BlocklistedWhileInTransaction,
    }

    def self.const_missing(const_name)
      if DEPRECATED_CLASSES.key? const_name
        replacement = DEPRECATED_CLASSES.fetch(const_name)

        warn "Makara::Errors::#{const_name} is deprecated. Switch to #{replacement}"

        replacement
      else
        super
      end
    end
  end

  module Logging
    autoload :Logger,     'makara/logging/logger'
    autoload :Subscriber, 'makara/logging/subscriber'
  end

  module Strategies
    autoload :Abstract,         'makara/strategies/abstract'
    autoload :RoundRobin,       'makara/strategies/round_robin'
    autoload :PriorityFailover, 'makara/strategies/priority_failover'
    autoload :ShardAware,       'makara/strategies/shard_aware'
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::LogSubscriber.log_subscribers.each do |subscriber|
    subscriber.extend ::Makara::Logging::Subscriber
  end
end
