module Makara
  module Strategies
    class PriorityFailover < ::Makara::Strategies::Abstract
      def init
        @current_idx = 0
        @weighted_connections = []
      end

      def connection_added(wrapper)
        # insert in weighted order
        @weighted_connections.each_with_index do |con, index|
          if wrapper._makara_weight > con._makara_weight
            @weighted_connections.insert(index, wrapper)
            return
          end
        end

        # else at end
        @weighted_connections << wrapper
      end

      def current
        safe_value(@current_idx)
      end

      def next
        @weighted_connections.each_with_index do |con, index|
          check = safe_value(index)
          next unless check

          @current_idx = index
          return check
        end

        nil
      end

      # return the connection if it's not blocklisted
      # otherwise return nil
      # optionally, store the position and context we're returning
      def safe_value(idx)
        con = @weighted_connections[idx]
        return nil unless con
        return nil if con._makara_blocklisted?

        con
      end
    end
  end
end
