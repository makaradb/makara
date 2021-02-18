require 'spec_helper'

describe Makara::ConnectionWrapper do
  let(:proxy){ FakeProxy.new({makara: {blacklist_duration: 5, connections: [{role: 'primary'}, {role: 'replica'}, {role: 'replica'}]}}) }
  let(:connection){ subject._makara_connection }

  subject{ proxy.primary_pool.connections.first }

  it 'should extend the connection with new functionality' do
    expect(connection).to respond_to(:_makara_name)
    expect(connection).to respond_to(:_makara)
    expect(connection).to respond_to(:_makara_hijack)
  end

  it 'should invoke hijacked methods on the proxy when invoked directly' do
    expect(proxy).to receive(:execute).with('test').once do |&block|
      expect(block.call).to eq('Hello')
    end

    connection.execute('test') { 'Hello' }
  end

  it 'should have a default weight of 1' do
    expect(subject._makara_weight).to eq(1)
  end

  context '#_makara_blacklisted?' do
    it 'should store the blacklist status' do
      expect(subject._makara_blacklisted?).to eq(false)
      subject._makara_blacklist!
      expect(subject._makara_blacklisted?).to eq(true)
      subject._makara_whitelist!
      expect(subject._makara_blacklisted?).to eq(false)
    end

    it 'should handle frozen pre-epoch dates' do
      Timecop.freeze(Date.new(1900)) do
        expect(subject._makara_blacklisted?).to eq(false)
      end
    end
  end

  describe '#_makara_connection' do
    it 'return connection when successfully connected' do
      expect(subject._makara_connection).to eq(connection)
    end

    it 'raise error when blacklisted with initial_error' do
      expect(subject).to receive(:initial_error).and_return(StandardError.new('some connection issue')).twice # master + slave
      subject._makara_blacklist!

      expect(proxy).not_to receive(:graceful_connection_for)

      expect{ subject._makara_connection }.to raise_error(Makara::Errors::BlacklistConnection)
    end

    context 'not connected' do
      it 'return connection when re-connecting successfully' do
        fake_connection = FakeConnection.new({:master_ttl=>5, :blacklist_duration=>5, :sticky=>true, :name=>"master/1"})

        subject.instance_variable_set(:@connection, nil)
        expect(proxy).to receive(:graceful_connection_for).and_return(fake_connection)

        expect(subject._makara_connection).to eq(fake_connection)
      end

      it 'raise error when unable to connect' do
        fake_connection = FakeConnection.new({:master_ttl=>5, :blacklist_duration=>5, :sticky=>true, :name=>"master/1"})
        connection_error = StandardError.new('some connection issue')
        expect(fake_connection).to receive(:is_a?).with(Makara::ConnectionWrapper).and_return(true)
        expect(fake_connection).to receive(:initial_error).and_return(connection_error)

        subject.instance_variable_set(:@connection, nil)
        expect(proxy).to receive(:graceful_connection_for).and_return(fake_connection)

        expect(subject).to receive(:_makara_blacklist!)
        expect{ subject._makara_connection }.to raise_error(Makara::Errors::BlacklistConnection)
      end
    end
  end
end
