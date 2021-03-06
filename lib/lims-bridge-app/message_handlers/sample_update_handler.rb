require 'lims-bridge-app/base_handler'
require 'lims-bridge-app/message_handlers/sample_shared'

module Lims::BridgeApp
  module MessageHandlers
    class SampleUpdateHandler < BaseHandler
      include SampleShared

      private

      def _call_in_transaction
        sample_handler do |sample, sample_uuid|
          sequencescape.update_sample(sample, sample_uuid)
        end
      end
    end
  end
end
