# Keeps track of the current stickiness state for different Makara proxies
module Makara
  class Context
    attr_accessor :stored_data, :staged_data
    attr_reader :current_timestamp

    def initialize(context_data)
      @stored_data = context_data
      @staged_data = {}
      @dirty = @was_dirty = false

      freeze_time
    end

    def stage(proxy_id, ttl)
      staged_data[proxy_id] = [staged_data[proxy_id].to_f, ttl.to_f].max
    end

    def stuck?(proxy_id)
      stored_data[proxy_id] && !expired?(stored_data[proxy_id])
    end

    def staged?(proxy_id)
      staged_data.key?(proxy_id)
    end

    def release(proxy_id)
      @dirty ||= !!stored_data.delete(proxy_id)
      staged_data.delete(proxy_id)
    end

    def release_all
      if self.stored_data.any?
        self.stored_data = {}
        # We need to track a change made to the current stored data
        # so we can commit it later
        @dirty = true
      end
      self.staged_data = {}
    end

    # Stores the staged data with an expiration time based on the current time,
    # and clears any expired entries. Returns true if any changes were made to
    # the current store
    def commit
      freeze_time
      release_expired
      store_staged_data
      clean

      was_dirty?
    end

    private

    def freeze_time
      @current_timestamp = Time.now.to_f
    end

    # Indicates whether there have been changes to the context that need
    # to be persisted when the request finishes
    def dirty?
      @dirty
    end

    def was_dirty?
      @was_dirty
    end

    def expired?(timestamp)
      timestamp <= current_timestamp
    end

    def release_expired
      previous_size = stored_data.size
      stored_data.delete_if { |_, timestamp| expired?(timestamp) }
      @dirty ||= previous_size != stored_data.size
    end

    def store_staged_data
      staged_data.each do |proxy_id, ttl|
        if ttl > 0 && self.stored_data[proxy_id].to_f < current_timestamp + ttl
          self.stored_data[proxy_id] = current_timestamp + ttl
          @dirty = true
        end
      end
    end

    def clean
      @was_dirty = dirty?
      @dirty = false
      @staged_data = {}
    end

    class << self
      def set_current(context_data)
        set(:makara_current_context, new(context_data))
      end

      # Called by `Proxy#stick_to_primary!` to use primary in subsequent requests
      def stick(proxy_id, ttl)
        current.stage(proxy_id, ttl)
      end

      def stuck?(proxy_id)
        current.staged?(proxy_id) || current.stuck?(proxy_id)
      end

      def next
        if current.commit
          current.stored_data
        end
      end

      def release(proxy_id)
        current.release(proxy_id)
      end

      def release_all
        current.release_all
      end

      protected

      def current
        fetch(:makara_current_context) { new({}) }
      end

      def fetch(key)
        get(key) || set(key, yield)
      end

      if Thread.current.respond_to?(:thread_variable_get)
        def get(key)
          Thread.current.thread_variable_get(key)
        end

        def set(key, value)
          Thread.current.thread_variable_set(key, value)
        end
      else
        def get(key)
          Thread.current[key]
        end

        def set(key, value)
          Thread.current[key]=value
        end
      end
    end
  end
end
