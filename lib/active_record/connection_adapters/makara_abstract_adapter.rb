require 'active_record'
require 'makara'

module ActiveRecord
  module ConnectionAdapters
    class MakaraAbstractAdapter < ::Makara::Proxy
      class ErrorHandler < ::Makara::ErrorHandler
        HARSH_ERRORS = [
          'ActiveRecord::RecordNotUnique',
          'ActiveRecord::InvalidForeignKey',
          'Makara::Errors::BlocklistConnection'
        ].map(&:freeze).freeze

        CONNECTION_MATCHERS = [
          /(closed|lost|no|terminating|terminated)\s?([^\s]+)?\sconnection/,
          /gone away/,
          /connection[^:]+refused/,
          /could not connect/,
          /can\'t connect/,
          /cannot connect/,
          /connection[^:]+closed/,
          /can\'t get socket descriptor/,
          /connection to [a-z0-9.]+:[0-9]+ refused/,
          /timeout expired/,
          /could not translate host name/,
          /timeout waiting for a response/,
          /the database system is (starting|shutting)/
        ].map(&:freeze).freeze

        def handle(connection)
          yield
        rescue Exception => e
          # do it via class name to avoid version-specific constant dependencies
          case e.class.name
          when *harsh_errors
            harshly(e)
          else
            if connection_message?(e) || custom_error_message?(connection, e)
              gracefully(connection, e)
            else
              harshly(e)
            end
          end
        end

        def harsh_errors
          HARSH_ERRORS
        end

        def connection_matchers
          CONNECTION_MATCHERS
        end

        def connection_message?(message)
          message = message.to_s.downcase

          case message
          when *connection_matchers
            true
          else
            false
          end
        end

        def custom_error_message?(connection, message)
          custom_error_matchers = connection._makara_custom_error_matchers
          return false if custom_error_matchers.empty?

          message = message.to_s

          custom_error_matchers.each do |matcher|
            if matcher.is_a?(String)

              # accept strings that look like "/.../" as a regex
              if matcher =~ /^\/(.+)\/([a-z])?$/

                options = $2 ? (($2.include?('x') ? Regexp::EXTENDED : 0) |
                          ($2.include?('i') ? Regexp::IGNORECASE : 0) |
                          ($2.include?('m') ? Regexp::MULTILINE : 0)) : 0

                matcher = Regexp.new($1, options)
              end
            end

            return true if matcher === message
          end

          false
        end
      end

      hijack_method :execute, :exec_query, :exec_no_cache, :exec_cache, :transaction
      send_to_all :connect, :reconnect!, :verify!, :clear_cache!, :reset!

      control_method :close, :steal!, :expire, :lease, :in_use?, :owner, :schema_cache, :pool=, :pool,
         :schema_cache=, :lock, :seconds_idle, :==

      SQL_PRIMARY_MATCHERS          = [/\A\s*select.+for update\Z/i, /select.+lock in share mode\Z/i, /\A\s*select.+(nextval|currval|lastval|get_lock|release_lock|pg_advisory_lock|pg_advisory_unlock)\(/i].map(&:freeze).freeze
      SQL_REPLICA_MATCHERS          = [/\A\s*(select|with.+\)\s*select)\s/i].map(&:freeze).freeze
      SQL_ALL_MATCHERS              = [/\A\s*set\s/i].map(&:freeze).freeze
      SQL_SKIP_STICKINESS_MATCHERS  = [/\A\s*show\s([\w]+\s)?(field|table|database|schema|view|index)(es|s)?/i, /\A\s*(set|describe|explain|pragma)\s/i].map(&:freeze).freeze

      SQL_MASTER_MATCHERS = SQL_PRIMARY_MATCHERS
      deprecate_constant :SQL_MASTER_MATCHERS
      SQL_SLAVE_MATCHERS = SQL_REPLICA_MATCHERS
      deprecate_constant :SQL_SLAVE_MATCHERS

      def sql_primary_matchers
        SQL_PRIMARY_MATCHERS
      end

      def sql_master_matchers
        warn "#{self.class}#sql_master_matchers is deprecated. Use #sql_primary_matchers"
        sql_primary_matchers
      end

      def sql_replica_matchers
        SQL_REPLICA_MATCHERS
      end

      def sql_slave_matchers
        warn "#{self.class}#sql_slave_matchers is deprecated. Use #sql_replica_matchers"
        sql_replica_matchers
      end

      def sql_all_matchers
        SQL_ALL_MATCHERS
      end

      def sql_skip_stickiness_matchers
        SQL_SKIP_STICKINESS_MATCHERS
      end

      def initialize(config)
        @error_handler = ::ActiveRecord::ConnectionAdapters::MakaraAbstractAdapter::ErrorHandler.new
        @control = ActiveRecordPoolControl.new(self)
        super(config)
      end

      protected

      def appropriate_connection(method_name, args, &block)
        if needed_by_all?(method_name, args)
          handling_an_all_execution(method_name) do
            hijacked do
              # replica pool must run first.
              @replica_pool.send_to_all(nil, &block) # just yields to each con
              @primary_pool.send_to_all(nil, &block) # just yields to each con
            end
          end
        else
          super(method_name, args) do |con|
            yield con
          end
        end
      end

      def should_stick?(method_name, args)
        sql = coerce_query_to_sql_string(args.first)
        return false if sql_skip_stickiness_matchers.any?{|m| sql =~ m }

        super
      end

      def needed_by_all?(method_name, args)
        sql = coerce_query_to_sql_string(args.first)
        return true if sql_all_matchers.any?{|m| sql =~ m }

        false
      end

      def needs_primary?(method_name, args)
        if respond_to?(:needs_master?)
          warn "#{self.class}#needs_master? is deprecated. Switch to #needs_primary?"
          needs_master?(method_name, args)
        else
          sql = coerce_query_to_sql_string(args.first)
          return true if sql_primary_matchers.any?{|m| sql =~ m }
          return false if sql_replica_matchers.any?{|m| sql =~ m }

          true
        end
      end

      def coerce_query_to_sql_string(sql_or_arel)
        if sql_or_arel.respond_to?(:to_sql)
          sql_or_arel.to_sql
        else
          sql_or_arel.to_s
        end
      end

      def connection_for(config)
        config = Makara::ConfigParser.merge_and_resolve_default_url_config(config)
        active_record_connection_for(config)
      end

      def active_record_connection_for(config)
        raise NotImplementedError
      end

      class ActiveRecordPoolControl
        attr_reader :owner
        alias :in_use? :owner

        def initialize(proxy)
          @proxy = proxy
          @owner = nil
          @pool = nil
          @schema_cache = ActiveRecord::ConnectionAdapters::SchemaCache.new @proxy
          @idle_since = Concurrent.monotonic_time
          @adapter = ActiveRecord::ConnectionAdapters::AbstractAdapter.new(@proxy)
        end

        def close(*args)
          @pool.checkin @proxy
        end

        # this method must only be called while holding connection pool's mutex
        def lease(*args)
          if in_use?
            msg = +"Cannot lease connection, "
            if @owner == Thread.current
              msg << "it is already leased by the current thread."
            else
              msg << "it is already in use by a different thread: #{@owner}. " \
                    "Current thread: #{Thread.current}."
            end
            raise ActiveRecordError, msg
          end
          @owner = Thread.current
        end

        # this method must only be called while holding connection pool's mutex
        def expire(*args)
          if in_use?
            if @owner != Thread.current
              raise ActiveRecordError, "Cannot expire connection, " \
                "it is owned by a different thread: #{@owner}. " \
                "Current thread: #{Thread.current}."
            end

            @idle_since = Concurrent.monotonic_time
            @owner = nil
          else
            raise ActiveRecordError, "Cannot expire connection, it is not currently leased."
          end
        end

        # Seconds since this connection was returned to the pool
        def seconds_idle(*args)
          return 0 if in_use?

          Concurrent.monotonic_time - @idle_since
        end

        # this method must only be called while holding connection pool's mutex (and a desire for segfaults)
        def steal!(*args)
          if in_use?
            if @owner != Thread.current
              @pool.send :remove_connection_from_thread_cache, @proxy, @owner
              @owner = Thread.current
            end
          else
            raise ActiveRecordError, "Cannot steal connection, it is not currently leased."
          end
        end

        def schema_cache(*args)
          if @pool.respond_to?(:get_schema_cache) # AR6
            @pool.get_schema_cache(@proxy)
          else
            @schema_cache
          end
        end

        def schema_cache=(*args)
          cache = args[0]
          cache.connection = @proxy
          if @pool.respond_to?(:set_schema_cache) # AR6
            @pool.set_schema_cache(cache)
          else
            @schema_cache = cache
          end
        end

        def lock(*args)
          @adapter.lock
        end

        def pool=(*args)
          @pool = args[0]
        end

        def pool(*args)
          @pool
        end

        def ==(*args)
          @proxy.object_id == args[0].object_id
        end
      end
    end
  end
end
