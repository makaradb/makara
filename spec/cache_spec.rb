require 'spec_helper'

describe Makara::Cache do

  it 'should not require a store be set' do
    described_class.store = nil

    expect(
      described_class.send(:store)
    ).to be_nil

    expect{
      described_class.read('test')
    }.not_to raise_error
  end

  it 'provides a few stores for testing purposes' do
    described_class.store = :memory
    described_class.write('test', 'value', 10)
    expect(described_class.read('test')).to eq('value')

    described_class.store = :noop
    described_class.write('test', 'value', 10)
    expect(described_class.read('test')).to be_nil
  end

  context 'notifications' do
    before { allow(Makara::Notifications).to receive(:notify!) }

    it 'notifies on read and write' do
      described_class.read('test')
      expect(Makara::Notifications).to have_received(:notify!).with('Cache:read', 'test', nil)
      described_class.write('test', 'value', 10)
      expect(Makara::Notifications).to have_received(:notify!).with('Cache:write', 'test', 'value', 10)
      described_class.read('test')
      expect(Makara::Notifications).to have_received(:notify!).with('Cache:read', 'test', 'value')
    end
  end

  # this will be used in tests so we have to ensure this works as expected
  context Makara::Cache::MemoryStore do

    let(:store){ Makara::Cache::MemoryStore.new }
    let(:data){ store.instance_variable_get('@data') }

    it 'should read and write keys' do
      expect(store.read('test')).to be_nil
      store.write('test', 'value')
      expect(store.read('test')).to eq('value')
    end

    it 'provides time based expiration' do
      store.write('test', 'value', :expires_in => 5)
      expect(store.read('test')).to eq('value')

      Timecop.travel Time.now + 6 do
        expect(store.read('test')).to be_nil
      end
    end

    it 'cleans the data' do
      store.write('test', 'value', :expires_in => -5)
      expect(store.read('test')).to be_nil
      expect(data).not_to have_key('test')
    end

  end



end
