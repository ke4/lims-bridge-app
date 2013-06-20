require 'lims-bridge-app/plate_creator/base_handler'

module Lims::BridgeApp::PlateCreator
  module MessageHandler
    class LabellableHandler < BaseHandler

      private

      def _call_in_transaction
        begin 
          if s2_resource.has_key?(:labellables)
            s2_resource[:labellables].each do |labellable|
              set_barcode_to_a_plate(labellable[:labellable])
            end
          else
            set_barcode_to_a_plate(s2_resource[:labellable])
          end
        rescue Sequel::Rollback, PlateNotFoundInSequencescape => e
          metadata.reject(:requeue => true)
          log.error("Error updating barcode in Sequencescape: #{e}")
          # Need to reraise a rollback exception as we are still 
          # in a sequel transaction block.
          raise Sequel::Rollback
        else
          metadata.ack
          log.info("Labellable message processed and acknowledged")
        end
      end
    end
  end
end