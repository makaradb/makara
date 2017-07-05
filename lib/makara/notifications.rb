module Makara
  # A notification handler that allows users to register arbitrary instrumentation callbacks. For instance, this can be
  # used to fire dtrace or strace probes, or to write log messages. Callbacks are in the form of blocks, which can take
  # 0 to N arguments, where N is the number of arguments provided to the the :notify!: method.
  #
  # Example:
  #
  #   Makara::Cache instruments the :write: method as follows:
  #
  #     Notifications.notify!('Cache:write', key, value, ttl)
  #
  #   Callbacks can be registered as follows:
  #
  #     Notifications.register_callback('Cache:write') do |key|
  #       puts "Makara::Cache.write: #{key}"
  #     end
  #
  #     Notifications.register_callback('Cache:write') do |key, value|
  #       puts "Makara::Cache.write: #{key}: #{value}"
  #     end
  #
  module Notifications
    class << self
      def register_callback(name, &blk)
        registered_callbacks[name] << blk
      end

      def notify!(name, *args)
        return unless registered_callbacks[name]
        registered_callbacks[name].each do |callback|
          callback.call(*args)
        end
      end

      def registered_callbacks
        @registered_callbacks ||= Hash.new([])
      end
    end
  end
end
