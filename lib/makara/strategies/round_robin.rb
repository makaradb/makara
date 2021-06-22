module Makara
  module Strategies
    class RoundRobin < ::Makara::Strategies::Abstract
      def init
        @current_idx = 0
        @weighted_connections = []
      end

      def connection_added(wrapper)
        # the weight results in N references to the connection, not N connections
        wrapper._makara_weight.times{ @weighted_connections << wrapper }

        if should_shuffle?
          # randomize the connections so we don't get peaks and valleys of load
          @weighted_connections.shuffle!
          # then start at a random spot in the list
          @current_idx = rand(@weighted_connections.length)
        end
      end

      def current
        safe_value(@current_idx)
      end

      def next
        return safe_value(0, true) if single_one?

        idx = @current_idx

        begin
          idx = next_index(idx)

          # if we've looped all the way around, return our safe value
          return safe_value(idx, true) if idx == @current_idx

        # while our current safe value is dangerous
        end while safe_value(idx).nil?

        # store our current spot and return our safe value
        safe_value(idx, true)
      end

      # next index within the bounds of the connections array
      # loop around when the end is hit
      def next_index(idx)
        idx = idx + 1
        idx = 0 if idx >= @weighted_connections.length
        idx
      end

      # return the connection if it's not blocklisted
      # otherwise return nil
      # optionally, store the position and context we're returning
      def safe_value(idx, stick = false)
        con = @weighted_connections[idx]
        return nil unless con
        return nil if con._makara_blocklisted?

        if stick
          @current_idx = idx
        end

        con
      end

      # stub in test mode to ensure consistency
      def should_shuffle?
        true
      end

      def single_one?
        false
      end
    end
  end
end
