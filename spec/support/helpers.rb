module SpecHelpers
  def establish_connection(config)
    connection = ActiveRecord::Base.establish_connection(config)

    # make sure these are all reset to not be blocklisted
    ActiveRecord::Base.connection.replica_pool.connections.each(&:_makara_allowlist!)
    ActiveRecord::Base.connection.primary_pool.connections.each(&:_makara_allowlist!)

    ActiveRecord::Base.connection
  end

  def config(primaries = 1, replicas = 2)
    connections = []
    primaries.times{ connections << {role: 'primary'} }
    replicas.times{ connections << {role: 'replica'} }
    {
      makara: {
        # Defaults:
        # :primary_ttl => 5,
        # :blocklist_duration => 30,
        # :sticky => true
        id: 'mock_mysql',
        connections: connections
      }
    }
  end
end
