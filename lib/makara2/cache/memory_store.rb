module Makara2
  module Cache
    class MemoryStore

      def initialize
        @data = {}
      end

      def read(key)
        clean
        @data[key].try(:[], 0)
      end

      def write(key, value, options = {})
        clean
        @data[key] = [value, Time.now.to_i + (options[:expires_in] || 5).to_i]
        true
      end

      protected

      def clean
        @data.delete_if{|k,v| v[1] <= Time.now.to_i }
      end

    end
  end
end