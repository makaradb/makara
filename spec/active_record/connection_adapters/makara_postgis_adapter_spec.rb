# RGeo doesn't play well with JRuby

require 'active_record'

if RUBY_ENGINE == 'ruby'
  require 'spec_helper'
  require 'rgeo'
  require 'activerecord-postgis-adapter'
  require 'active_record/connection_adapters/postgis_adapter'

  describe 'MakaraPostgisAdapter' do
    let(:config) do
      YAML.load_file(File.expand_path('spec/support/postgis_database.yml'))['test']
    end

    let(:connection) { ActiveRecord::Base.connection }

    before :each do
      ActiveRecord::Base.clear_all_connections!
      change_context
    end

    it 'should allow a connection to be established' do
      ActiveRecord::Base.establish_connection(config)
      expect(ActiveRecord::Base.connection)
        .to be_instance_of(ActiveRecord::ConnectionAdapters::MakaraPostgisAdapter)
    end

    context 'with the connection established and schema loaded' do
      before do
        ActiveRecord::Base.establish_connection(config)
        load(File.dirname(__FILE__) + '/../../support/schema.rb')
        load(File.dirname(__FILE__) + '/../../support/postgis_schema.rb')
        change_context
        RGeo::ActiveRecord::SpatialFactoryStore.instance.tap do |config|
          # By default, use the GEOS implementation for spatial columns.
          config.default = RGeo::Geos.factory_generator

          # But use a geographic implementation for point columns.
          config.register(RGeo::Geographic.spherical_factory(srid: 4326), geo_type: "point")
        end
      end

      let(:town_class) do
        Class.new(ActiveRecord::Base) do
          self.table_name = :towns
        end
      end

      it 'should have one primary and two replicas' do
        expect(connection.primary_pool.connection_count).to eq(1)
        expect(connection.replica_pool.connection_count).to eq(2)
      end

      it 'should allow real queries to work' do
        connection.execute('INSERT INTO users (name) VALUES (\'John\')')

        connection.primary_pool.connections.each do |primary|
          expect(primary).to receive(:execute).never
        end

        change_context
        res = connection.execute('SELECT name FROM users ORDER BY id DESC LIMIT 1')

        expect(res.to_a[0]['name']).to eq('John')
      end

      it 'should send SET operations to each connection' do
        connection.primary_pool.connections.each do |con|
          expect(con).to receive(:execute).with("SET TimeZone = 'UTC'").once
        end

        connection.replica_pool.connections.each do |con|
          expect(con).to receive(:execute).with("SET TimeZone = 'UTC'").once
        end
        connection.execute("SET TimeZone = 'UTC'")
      end

      it 'should send reads to the replica' do
        # ensure the next connection will be the first one
        allow_any_instance_of(Makara::Strategies::RoundRobin).to receive(:single_one?){ true }

        con = connection.replica_pool.connections.first
        expect(con).to receive(:execute).with('SELECT * FROM users').once

        connection.execute('SELECT * FROM users')
      end

      it 'should send writes to primary' do
        con = connection.primary_pool.connections.first
        expect(con).to receive(:execute).with('UPDATE users SET name = "bob" WHERE id = 1')
        connection.execute('UPDATE users SET name = "bob" WHERE id = 1')
      end

      it 'should interpret points correctly' do
        town_class.create!(location: 'Point(1 2)')
        town = town_class.last
        expect(town.location.x).to eq 1
        expect(town.location.y).to eq 2
      end
    end

    context 'without live connections' do
      it 'should raise errors on read or write' do
        allow(ActiveRecord::Base).to receive(:postgis_connection).and_raise(StandardError.new('could not connect to server: Connection refused'))

        ActiveRecord::Base.establish_connection(config)
        expect { connection.execute('SELECT * FROM users') }.to raise_error(Makara::Errors::NoConnectionsAvailable)
        expect { connection.execute('INSERT INTO users (name) VALUES (\'John\')') }.to raise_error(Makara::Errors::NoConnectionsAvailable)
      end
    end

    context 'with only primary connection' do
      it 'should not raise errors on read and write' do
        custom_config = config.deep_dup
        custom_config['makara']['connections'].select{|h| h['role'] == 'replica' }.each{|h| h['port'] = '1'}

        ActiveRecord::Base.establish_connection(custom_config)
        load(File.dirname(__FILE__) + '/../../support/schema.rb')

        connection.execute('SELECT * FROM users')
        connection.execute('INSERT INTO users (name) VALUES (\'John\')')
      end
    end

    context 'with only replica connection' do
      it 'should raise error only on write' do
        ActiveRecord::Base.establish_connection(config)
        load(File.dirname(__FILE__) + '/../../support/schema.rb')
        ActiveRecord::Base.clear_all_connections!

        custom_config = config.deep_dup
        custom_config['makara']['connections'].select{|h| h['role'] == 'primary' }.each{|h| h['port'] = '1'}

        ActiveRecord::Base.establish_connection(custom_config)

        connection.execute('SELECT * FROM users')
        expect { connection.execute('INSERT INTO users (name) VALUES (\'John\')') }.to raise_error(Makara::Errors::NoConnectionsAvailable)
      end
    end
  end
end
