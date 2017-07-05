require 'delegate'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/string/inflections'

# The entry point of Makara. It contains a master and slave pool which are chosen based on the invocation
# being proxied. Makara::Proxy implementations should declare which methods they are hijacking via the
# `hijack_method` class method.
# While debugging this class use prepend debug calls with Kernel. (Kernel.byebug for example)
# to avoid getting into method_missing stuff.

module Makara
  class Proxy < ::SimpleDelegator

    METHOD_MISSING_SKIP = [ :byebug, :puts ]

    class_attribute :hijack_methods
    self.hijack_methods = []

    class << self
      def hijack_method(*method_names)
        self.hijack_methods = self.hijack_methods || []
        self.hijack_methods |= method_names

        method_names.each do |method_name|
          define_method method_name do |*args, &block|
            appropriate_connection(method_name, args) do |con|
              con.send(method_name, *args, &block)
            end
          end
        end
      end

      def send_to_all(*method_names)
        method_names.each do |method_name|
          define_method method_name do |*args|
            send_to_all method_name, *args
          end
        end
      end
    end


    attr_reader :error_handler
    attr_reader :sticky
    attr_reader :config_parser

    def initialize(config)
      @config         = config.symbolize_keys
      @config_parser  = Makara::ConfigParser.new(@config)
      @id             = @config_parser.id
      @ttl            = @config_parser.makara_config[:master_ttl]
      @sticky         = @config_parser.makara_config[:sticky]
      @hijacked       = false
      @error_handler  ||= ::Makara::ErrorHandler.new
      @skip_sticking  = false
      instantiate_connections
      super(config)
    end

    def without_sticking
      before_context = @master_context
      @master_context = nil
      @skip_sticking = true
      yield
    ensure
      @skip_sticking = false
      @master_context ||= before_context
    end

    def hijacked?
      @hijacked
    end

    def stick_to_master!(write_to_cache = true)
      @master_context = Makara::Context.get_current
      Makara::Cache.write("makara::#{@master_context}-#{@id}", '1', @ttl) if write_to_cache
    end

    def strategy_for(role)
      strategy_name = @config_parser.makara_config["#{role}_strategy".to_sym]
      case strategy_name
      when 'round_robin', 'roundrobin', nil, ''
        strategy_name = "::Makara::Strategies::RoundRobin"
      when 'failover'
        strategy_name = "::Makara::Strategies::PriorityFailover"
      end
      strategy_name.constantize.new(self)
    end

    def method_missing(m, *args, &block)
      if METHOD_MISSING_SKIP.include?(m)
        return super(m, *args, &block)
      end

      any_connection do |con|
        if con.respond_to?(m)
          con.public_send(m, *args, &block)
        elsif con.respond_to?(m, true)
          con.__send__(m, *args, &block)
        else
          super(m, *args, &block)
        end
      end
    end

    class_eval <<-RUBY_EVAL, __FILE__, __LINE__ + 1
      def respond_to#{RUBY_VERSION.to_s =~ /^1.8/ ? nil : '_missing'}?(m, include_private = false)
        any_connection do |con|
          con._makara_connection.respond_to?(m, true)
        end
      end
    RUBY_EVAL

    def graceful_connection_for(config)
      fake_wrapper = Makara::ConnectionWrapper.new(self, nil, config)

      @error_handler.handle(fake_wrapper) do
        connection_for(config)
      end
    rescue Makara::Errors::BlacklistConnection => e
      fake_wrapper.initial_error = e.original_error
      fake_wrapper
    end

    def disconnect!
      send_to_all(:disconnect!)
    rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable
      # all connections are already down, nothing to do here
    end

    protected


    def send_to_all(method_name, *args)
      # slave pool must run first to allow for slave-->master failover without running operations on master twice.
      handling_an_all_execution(method_name) do
        @slave_pool.send_to_all method_name, *args
        @master_pool.send_to_all method_name, *args
      end
    end

    def any_connection
      @master_pool.provide do |con|
        yield con
      end
    rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable
      begin
        @master_pool.disabled = true
        @slave_pool.provide do |con|
          yield con
        end
      ensure
        @master_pool.disabled = false
      end
    end

    # based on the method_name and args, provide the appropriate connection
    # mark this proxy as hijacked so the underlying connection does not attempt to check
    # with back with this proxy.
    def appropriate_connection(method_name, args)
      appropriate_pool(method_name, args) do |pool|
        pool.provide do |connection|
          hijacked do
            yield connection
          end
        end
      end
    end


    # master or slave
    def appropriate_pool(method_name, args)

      # for testing purposes
      pool = _appropriate_pool(method_name, args)

      yield pool

    rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable => e
      if pool == @master_pool
        @master_pool.connections.each(&:_makara_whitelist!)
        @slave_pool.connections.each(&:_makara_whitelist!)
        Kernel.raise e
      else
        @master_pool.blacklist_errors << e
        retry
      end
    end

    def _appropriate_pool(method_name, args)
      # the args provided absolutely need master
      if needs_master?(method_name, args)
        Notifications.notify!('Proxy:appropriate_pool:master')
        stick_to_master(method_name, args)
        @master_pool

      # in this context, we've already stuck to master
      elsif Makara::Context.get_current == @master_context
        Notifications.notify!('Proxy:appropriate_pool:master')
        @master_pool

      # the previous context stuck us to master
      elsif previously_stuck_to_master?
        Notifications.notify!('Proxy:appropriate_pool:master')

        # we're only on master because of the previous context so
        # behave like we're sticking to master but store the current context
        stick_to_master(method_name, args, false)
        @master_pool

      # all slaves are down (or empty)
      elsif @slave_pool.completely_blacklisted?
        Notifications.notify!('Proxy:appropriate_pool:master')
        stick_to_master(method_name, args)
        @master_pool

      elsif in_transaction?
        @master_pool

      # yay! use a slave
      else
        Notifications.notify!('Proxy:appropriate_pool:replica')
        @slave_pool
      end
    end

    # do these args require a master connection
    def needs_master?(method_name, args)
      true
    end

    def in_transaction?
      if respond_to?(:open_transactions)
        self.open_transactions > 0
      else
        false
      end
    end

    def hijacked
      @hijacked = true
      yield
    ensure
      @hijacked = false
    end


    def previously_stuck_to_master?
      return false unless @sticky
      !!Makara::Cache.read("makara::#{Makara::Context.get_previous}-#{@id}")
    end


    def stick_to_master(method_name, args, write_to_cache = true)
      Notifications.notify!('Proxy:stick_to_master', method_name, args, write_to_cache)
      # if we're already stuck to master, don't bother doing it again
      return if @master_context == Makara::Context.get_current

      # check to see if we're configured, bypassed, or some custom implementation has input
      return unless should_stick?(method_name, args)

      # do the sticking
      stick_to_master!(write_to_cache)
    end


    # if we are configured to be sticky and we aren't bypassing stickiness
    def should_stick?(method_name, args)
      @sticky && !@skip_sticking
    end


    # use the config parser to generate a master and slave pool
    def instantiate_connections
      @master_pool = Makara::Pool.new('master', self)
      @config_parser.master_configs.each do |master_config|
        @master_pool.add master_config do
          graceful_connection_for(master_config)
        end
      end

      @slave_pool = Makara::Pool.new('slave', self)
      @config_parser.slave_configs.each do |slave_config|
        @slave_pool.add slave_config do
          graceful_connection_for(slave_config)
        end
      end
    end

    def handling_an_all_execution(method_name)
      yield
    rescue ::Makara::Errors::NoConnectionsAvailable => e
      if e.role == 'master'
        Kernel.raise ::Makara::Errors::NoConnectionsAvailable.new('master and slave')
      end
      @slave_pool.disabled = true
      yield
    ensure
      @slave_pool.disabled = false
    end


    def connection_for(config)
      Kernel.raise NotImplementedError
    end

  end
end
