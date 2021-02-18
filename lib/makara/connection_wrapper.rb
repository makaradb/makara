require 'active_support/core_ext/hash/keys'

# Makara::ConnectionWrapper wraps the instance of an underlying connection.
# The wrapper provides methods for tracking blacklisting and individual makara configurations.
# Upon creation, the wrapper defines methods in the underlying object giving it access to the
# Makara::Proxy.

module Makara
  class ConnectionWrapper
    attr_accessor :initial_error, :config

    # invalid queries caused by connections switching that needs to be replaced
    SQL_REPLACE = {"SET client_min_messages TO ''".freeze => "SET client_min_messages TO 'warning'".freeze}.freeze

    def initialize(proxy, connection, config)
      @config = config.symbolize_keys
      @connection = connection
      @proxy = proxy

      if connection.nil?
        _makara_blacklist!
      else
        _makara_decorate_connection(connection)
      end
    end

    # the weight of the current node
    def _makara_weight
      @config[:weight] || 1
    end

    # the name of this node
    def _makara_name
      @config[:name]
    end

    def _makara_shard_id
      @config[:shard_id]
    end

    # has this node been blacklisted?
    def _makara_blacklisted?
      @blacklisted_until.present? && @blacklisted_until.to_i > Time.now.to_i
    end

    def _makara_in_transaction?
      @connection && @connection.open_transactions > 0
    end

    # blacklist this node for @config[:blacklist_duration] seconds
    def _makara_blacklist!
      @connection.disconnect! if @connection
      @connection = nil
      @blacklisted_until = Time.now.to_i + @config[:blacklist_duration] unless @config[:disable_blacklist]
    end

    # release the blacklist
    def _makara_whitelist!
      @blacklisted_until = nil
    end

    # custom error messages
    def _makara_custom_error_matchers
      @custom_error_matchers ||= (@config[:connection_error_matchers] || [])
    end

    def _makara_connected?
      _makara_connection.present?
    rescue Makara::Errors::BlacklistConnection
      false
    end

    def _makara_connection
      if _makara_blacklisted? && initial_error
        raise Makara::Errors::BlacklistConnection.new(self, initial_error)
      end

      current = @connection

      if current
        current
      else # blacklisted connection or initial error
        new_connection = @proxy.graceful_connection_for(@config)

        # Already wrapped because of initial failure
        if new_connection.is_a?(Makara::ConnectionWrapper)
          initial_error = new_connection.initial_error
          _makara_blacklist!
          raise Makara::Errors::BlacklistConnection.new(self, initial_error)
        else
          @connection = new_connection
          _makara_decorate_connection(new_connection)
          new_connection
        end
      end
    end

    def execute(*args)
      SQL_REPLACE.each do |find, replace|
        if args[0] == find
          args[0] = replace
        end
      end

      _makara_connection.execute(*args)
    end

    # we want to forward all private methods, since we could have kicked out from a private scenario
    def method_missing(m, *args, &block)
      _makara_connection.send(m, *args, &block)
    end

    ruby2_keywords :method_missing if Module.private_method_defined?(:ruby2_keywords)

    def respond_to_missing?(m, include_private = false)
      _makara_connection.respond_to?(m, true)
    end

    protected

    # once the underlying connection is present we must evaluate extra functionality into it.
    # all extra functionality is in the format of _makara*
    def _makara_decorate_connection(con)
      extension = <<~RUBY
        # the proxy object controlling this connection
        def _makara
          @_makara
        end

        def _makara=(m)
          @_makara = m
        end

        # if the proxy has already decided the correct connection to use, yield nil.
        # if the proxy has yet to decide, yield the proxy
        def _makara_hijack
          if _makara.hijacked?
            yield nil
          else
            yield _makara
          end
        end

        # for logging, errors, and debugging
        def _makara_name
          #{@config[:name].inspect}
        end
      RUBY

      args = RUBY_VERSION >= "3.0.0" ? "..." : "*args, &block"

      # Each method the Makara::Proxy needs to hijack should be redefined in the underlying connection.
      # The new definition should allow for the proxy to intercept the invocation if required.
      @proxy.class.hijack_methods.each do |meth|
        method_call = RUBY_VERSION >= "3.0.0" ? "public_send(#{meth.inspect}, ...)" : "#{meth}(*args, &block)"

        extension << <<~RUBY
          def #{meth}(#{args})
            _makara_hijack do |proxy|
              if proxy
                proxy.#{method_call}
              else
                super
              end
            end
          end
        RUBY
      end

      # Control methods must always be passed to the
      # Makara::Proxy control object for handling (typically
      # related to ActiveRecord connection pool management)
      @proxy.class.control_methods.each do |meth|
        method_call = RUBY_VERSION >= "3.0.0" ? "public_send(#{meth.inspect}, ...)" : "#{meth}(*args=args, block)"

        extension << <<~RUBY
          def #{meth}(#{args})
            proxy = _makara
            if proxy
              proxy.control.#{method_call}
            else
              super # Only if we are not wrapped any longer
            end
          end
        RUBY
      end

      # extend the instance
      con.instance_eval(extension, __FILE__, __LINE__ + 1)
      # set the makara context
      con._makara = @proxy

      con._makara
    end
  end
end
