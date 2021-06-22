require 'spec_helper'

describe Makara::Pool do
  let(:proxy){ FakeProxy.new({makara: pool_config.merge(connections: [])}) }
  let(:pool){ Makara::Pool.new('test', proxy) }
  let(:pool_config){ {blocklist_duration: 5} }
  let(:primary_pool){ Makara::Pool.new('primary', proxy) }

  it 'should wrap connections with a ConnectionWrapper as theyre added to the pool' do
    expect(pool.connections).to be_empty

    connection_a = FakeConnection.new(something: 'a')

    wrapper_a = pool.add(pool_config){ connection_a }
    wrapper_b = pool.add(pool_config.merge(weight: 2)){ FakeConnection.new }

    connections = pool.connections
    weighted_connections = pool.strategy.instance_variable_get("@weighted_connections")
    expect(connections.length).to eq(2)
    expect(weighted_connections.length).to eq(3)

    expect(wrapper_a).to be_a(Makara::ConnectionWrapper)
    expect(wrapper_a.irespondtothis).to eq('hey!')

    as, bs = weighted_connections.partition{|c| c.something == 'a'}
    expect(as.length).to eq(1)
    expect(bs.length).to eq(2)
  end

  it 'should determine if its completely blocklisted' do
    pool.add(pool_config){ FakeConnection.new }
    pool.add(pool_config){ FakeConnection.new }

    expect(pool).not_to be_completely_blocklisted

    pool.connections.each(&:_makara_blocklist!)

    expect(pool).to be_completely_blocklisted
  end

  it 'sends methods to all underlying objects if asked to' do
    a = FakeConnection.new
    b = FakeConnection.new

    pool.add(pool_config){ a }
    pool.add(pool_config){ b }

    expect(a).to receive(:query).with('test').once
    expect(b).to receive(:query).with('test').once

    pool.send_to_all :query, 'test'
  end

  it 'only sends methods to underlying objects which are not blocklisted' do
    a = FakeConnection.new
    b = FakeConnection.new
    c = FakeConnection.new

    pool.add(pool_config){ a }
    pool.add(pool_config){ b }
    wrapper_c = pool.add(pool_config){ c }

    expect(a).to receive(:query).with('test').once
    expect(b).to receive(:query).with('test').once
    expect(c).to receive(:query).with('test').never

    wrapper_c._makara_blocklist!

    pool.send_to_all :query, 'test'
  end

  it 'provides the next connection and blocklists' do
    connection_a = FakeConnection.new(something: 'a')
    connection_b = FakeConnection.new(something: 'b')

    wrapper_a = pool.add(pool_config){ connection_a }
    wrapper_b = pool.add(pool_config){ connection_b }

    pool.provide do |connection|
      if connection == wrapper_a
        raise Makara::Errors::BlocklistConnection.new(wrapper_a, StandardError.new('failure'))
      end
    end

    expect(wrapper_a._makara_blocklisted?).to eq(true)
    expect(wrapper_b._makara_blocklisted?).to eq(false)

    Timecop.travel Time.now + 10 do
      expect(wrapper_a._makara_blocklisted?).to eq(false)
      expect(wrapper_b._makara_blocklisted?).to eq(false)
    end
  end

  it 'provides the same connection if the context has not changed and the proxy is sticky' do
    allow(proxy).to receive(:sticky){ true }

    pool.add(pool_config){ FakeConnection.new }
    pool.add(pool_config){ FakeConnection.new }

    provided = []

    10.times{ pool.provide{|con| provided << con } }

    expect(provided.uniq.length).to eq(1)
  end

  it 'does not provide the same connection if the proxy is not sticky' do
    allow(proxy).to receive(:sticky){ false }

    pool.add(pool_config){ FakeConnection.new }
    pool.add(pool_config){ FakeConnection.new }

    provided = []

    10.times{ pool.provide{|con| provided << con } }

    expect(provided.uniq.length).to eq(2)
  end

  it 'raises an error when all connections are blocklisted' do
    wrapper_a = pool.add(pool_config.dup){ FakeConnection.new }
    wrapper_b = pool.add(pool_config.dup){ FakeConnection.new }

    # make the connection
    pool.send_to_all :to_s

    allow(pool).to receive(:next).and_return(wrapper_a, wrapper_b, nil)

    begin
      pool.provide do |connection|
        raise Makara::Errors::BlocklistConnection.new(connection, StandardError.new('failure'))
      end
    rescue Makara::Errors::AllConnectionsBlocklisted => e
      expect(e).to be_present
      expect(e.message).to eq("[Makara/test] All connections are blocklisted -> [Makara/test/2] failure -> [Makara/test/1] failure")
    end
  end

  it 'skips blocklisted connections when choosing the next one' do
    pool.add(pool_config){ FakeConnection.new }
    pool.add(pool_config){ FakeConnection.new }

    wrapper_b = pool.add(pool_config){ FakeConnection.new }
    wrapper_b._makara_blocklist!

    10.times{ pool.provide{|connection| expect(connection).not_to eq(wrapper_b) } }
  end

  it 'should error out while blocklisted in transaction' do
    wrapper_a = primary_pool.add(pool_config){ FakeConnection.new(open_transactions: 1) }
    primary_pool.add(pool_config){ FakeConnection.new }
    expect {
      primary_pool.provide do |connection|
        if connection == wrapper_a
          raise Makara::Errors::BlocklistConnection.new(wrapper_a, StandardError.new('failure'))
        end
      end
    }.to raise_error(Makara::Errors::BlocklistedWhileInTransaction)
  end

  it 'skips blocklisted connections in primary pool when not in transaction' do
    wrapper_a = primary_pool.add(pool_config){ FakeConnection.new(open_transactions: 0) }
    primary_pool.add(pool_config){ FakeConnection.new }
    primary_pool.provide do |connection|
      if connection == wrapper_a
        raise Makara::Errors::BlocklistConnection.new(wrapper_a, StandardError.new('failure'))
      end
    end
    10.times{ primary_pool.provide{|connection| expect(connection).not_to eq(wrapper_a) } }
  end
end
