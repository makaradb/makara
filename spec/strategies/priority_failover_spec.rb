require 'spec_helper'

describe Makara::Strategies::PriorityFailover do
  let(:proxy){ FakeProxy.new({makara: pool_config.merge(makara_config).merge(connections: [])}) }
  let(:pool){ Makara::Pool.new('primary', proxy) }
  let(:pool_config){ {blocklist_duration: 5} }
  let(:makara_config) { { primary_strategy: 'failover' } }
  let(:strategy) { pool.strategy }

  it 'should use the strategy' do
    expect(pool.strategy).to be_instance_of(Makara::Strategies::PriorityFailover)
  end

  it 'should take the top weight' do
    wrapper_a = pool.add(pool_config){ FakeConnection.new(something: 'a') }
    wrapper_b = pool.add(pool_config){ FakeConnection.new(something: 'b') }
    wrapper_c = pool.add(pool_config.merge(weight: 2)){ FakeConnection.new(something: 'c') }

    expect(strategy.current.something).to eql('c')
    expect(strategy.next.something).to eql('c')
    expect(strategy.next.something).to eql('c')
  end

  it 'should take given order if no weights' do
    wrapper_a = pool.add(pool_config){ FakeConnection.new(something: 'a') }
    wrapper_b = pool.add(pool_config){ FakeConnection.new(something: 'b') }
    wrapper_c = pool.add(pool_config){ FakeConnection.new(something: 'c') }

    expect(strategy.current.something).to eql('a')
    expect(strategy.next.something).to eql('a')
  end

  it 'should handle failover to next one' do
    wrapper_a = pool.add(pool_config){ FakeConnection.new(something: 'a') }
    wrapper_b = pool.add(pool_config){ FakeConnection.new(something: 'b') }
    wrapper_c = pool.add(pool_config){ FakeConnection.new(something: 'c') }

    pool.provide do |connection|
      if connection == wrapper_a
        raise Makara::Errors::BlocklistConnection.new(wrapper_a, StandardError.new('failure'))
      end
    end

    # skips a
    expect(strategy.current.something).to eql('b')
    expect(strategy.next.something).to eql('b')
  end
end
