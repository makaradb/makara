module Makara
  module Errors
    class BlocklistConnection < MakaraError
      attr_reader :original_error

      def initialize(connection, error)
        @original_error = error
        super "[Makara/#{connection._makara_name}] #{error.message}"
      end
    end
  end
end
