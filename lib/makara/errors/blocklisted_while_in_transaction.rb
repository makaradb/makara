module Makara
  module Errors
    class BlocklistedWhileInTransaction < MakaraError
      attr_reader :role

      def initialize(role)
        @role = role
        super "[Makara] Blocklisted while in transaction in the #{role} pool"
      end
    end
  end
end
