require 'active_record/connection_adapters/makara_abstract_adapter'
require 'active_record/connection_adapters/postgis_adapter'

if ActiveRecord::VERSION::MAJOR >= 4
  module ActiveRecord
    module ConnectionHandling
      def postgis_makara_connection(config)
        ActiveRecord::ConnectionAdapters::PostgisMakaraAdapter.new(config)
      end
    end
  end
else
  module ActiveRecord
    class Base
      def self.postgis_makara_connection(config)
        ActiveRecord::ConnectionAdapters::PostgisMakaraAdapter.new(config)
      end
    end
  end
end

module ActiveRecord
  module ConnectionAdapters
    class PostgisMakaraAdapter < ActiveRecord::ConnectionAdapters::MakaraAbstractAdapter
      def self.visitor_for(*args)
        ActiveRecord::ConnectionAdapters::PostGISAdapter.visitor_for(*args)
      end

      protected

      def active_record_connection_for(config)
        ::ActiveRecord::Base.postgis_connection(config)
      end
    end
  end
end
