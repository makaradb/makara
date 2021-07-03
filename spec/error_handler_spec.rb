require "spec_helper"

describe Makara::ErrorHandler do
  let(:handler){ described_class.new }

  before{ allow(::Makara::Logging::Logger).to receive(:log) }

  describe "#harshly" do
    subject{ handler.send(:harshly, error) }

    context "an error with a backtrace" do
      let(:error){ StandardError.new }

      before do
        error.set_backtrace(caller)
        expect(error.backtrace).not_to be_nil
      end

      it "re-raises the original exception and logs with a backtrace" do
        expect{ subject }.to raise_error(error)
        expect(::Makara::Logging::Logger).to have_received(:log).with(/Harshly handling: StandardError\s+.+/i)
      end
    end

    context "an error without a backtrace" do
      let(:error){ StandardError.new }

      before { expect(error.backtrace).to be_nil }

      it "re-raises the original exception and logs without a backtrace" do
        expect{ subject }.to raise_error(error)
        expect(::Makara::Logging::Logger).to have_received(:log).with("Harshly handling: StandardError\n")
      end

    end
  end

end
