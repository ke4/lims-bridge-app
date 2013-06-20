require 'lims-management-app/sample/sample'
require 'lims-bridge-app/base_json_decoder'
require 'json'

module Lims::BridgeApp
  module SampleManagement
    module JsonDecoder
      include BaseJsonDecoder

      module SampleJsonDecoder
        def self.call(json, options)
          sample_hash = json["sample"]
          sample(sample_hash, options)
        end

        def self.sample(sample_hash, options)
          sample = Lims::ManagementApp::Sample.new
          sample_hash.each do |k,v|
            # we use sanger_sample_id for the name of sample in Sequencescape
            # It can only contains: letters, number, '_' or '-'
            if k == "sanger_sample_id"
              v.delete!("^a-zA-Z0-9_-")
            end
            sample.send("#{k}=", v) if sample.respond_to?("#{k}=")
          end

          {:sample => sample, :uuid => sample_hash["uuid"], :date => options[:date]}
        end
      end

      module BulkSampleJsonDecoder
        def self.call(action, json, options)
          bulk_sample_hash = json[action.to_s]
          samples_hash = bulk_sample_hash["result"]["samples"]
          samples = []
          samples_hash.each do |sample_hash|
            samples << JsonDecoder::SampleJsonDecoder.sample(sample_hash, options) 
          end

          {:samples => samples}
        end
      end

      module BulkCreateSampleJsonDecoder
        def self.call(json, options)
          BulkSampleJsonDecoder.call("bulk_create_sample", json, options)
        end
      end

      module BulkUpdateSampleJsonDecoder
        def self.call(json, options)
          BulkSampleJsonDecoder.call("bulk_update_sample", json, options)
        end
      end

      module BulkDeleteSampleJsonDecoder
        def self.call(json, options)
          BulkSampleJsonDecoder.call("bulk_delete_sample", json, options)
        end
      end
    end
  end
end
