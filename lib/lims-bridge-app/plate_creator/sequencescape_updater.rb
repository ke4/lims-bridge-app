require 'sequel'
require 'facets'

module Lims::BridgeApp
  module PlateCreator
    module SequencescapeUpdater

      WELL = "Well"
      PLATE = "Plate"
      ASSET = "Asset"
      SAMPLE = "Sample"
      STOCK_PLATE_PURPOSE_ID = 2
      STOCK_RNA_PLATE_PURPOSE_ID = 183
      UNASSIGNED_PLATE_PURPOSE_ID = 2
      STOCK_PLATES = ["stock"]
      ITEM_DONE_STATUS = "done"
      SANGER_BARCODE_TYPE = "sanger-barcode"
      PLATE_LOCATION = "Sample logistics freezer"

      REQUEST_STI_TYPE = "CreateAssetRequest"
      REQUEST_TYPE_ID = 11
      REQUEST_STATE = "passed"

      BARCODE_PREFIXES = ["ND", "NR"]

      # Exception raised after an unsuccessful lookup for a plate 
      # in Sequencescape database.
      PlateNotFoundInSequencescape = Class.new(StandardError)
      UnknownSample = Class.new(StandardError)
      UnknownLocation = Class.new(StandardError)
      InvalidBarcode = Class.new(StandardError)

      # Ensure that all the requests for a message are made in a
      # transaction.
      def call
        db.transaction do
          _call_in_transaction
        end
      end

      # Create a plate in Sequencescape database.
      # The following tables are updated:
      # - Assets (the plate is saved with a Unassigned plate purpose)
      # - Assets (each well of the plate are saved with the right map_id)
      # - Uuids (the external id is S2 uuid)
      # - Container_associations (to link each well to the plate in Assets)
      # If the transaction fails, it raises a Sequel::Rollback exception and 
      # the transaction rollbacks.
      # @param [Lims::Core::Laboratory::Plate] plate
      # @param [String] plate uuid
      # @param [Time] date
      # @param [Hash] sample uuids
      def create_plate_in_sequencescape(plate, plate_uuid, date, sample_uuids)
        asset_size = plate.number_of_rows * plate.number_of_columns

        # Save plate and plate uuid
        plate_id = db[:assets].insert(
          :sti_type => PLATE,
          :plate_purpose_id => UNASSIGNED_PLATE_PURPOSE_ID,
          :size => asset_size,
          :created_at => date,
          :updated_at => date
        ) 

        db[:uuids].insert(
          :resource_type => ASSET,
          :resource_id => plate_id,
          :external_id => plate_uuid
        ) 

        set_plate_location(plate_id)

        # Save wells and set the associations with the plate
        plate.keys.each do |location|
          map_id = db[:maps].select(:id).where(
            :description => location, 
            :asset_size => asset_size
          ).first[:id]

          well_id = db[:assets].insert(
            :sti_type => WELL, 
            :map_id => map_id,
            :created_at => date,
            :updated_at => date
          ) 

          db[:container_associations].insert(
            :container_id => plate_id, 
            :content_id => well_id
          ) 

          # Save well aliquots
          if sample_uuids.has_key?(location)
            sample_uuids[location].each do |sample_uuid|
              sample_resource_uuid = db[:uuids].select(:resource_id).where(
                :resource_type => SAMPLE, 
                :external_id => sample_uuid
              ).first

              raise UnknownSample, "The sample #{sample_uuid} cannot be found in Sequencescape" unless sample_resource_uuid
              sample_id = sample_resource_uuid[:resource_id]

              tag_id = get_tag_id(sample_id)
              study_id = study_id(sample_id)
              set_request!(well_id, study_id, date)

              db[:aliquots].insert(
                :receptacle_id => well_id, 
                :study_id => study_id,
                :sample_id => sample_id,
                :created_at => date,
                :updated_at => date,
                :tag_id => tag_id
              )
            end
          end 
        end
      end

      # @param [Integer] plate_id
      def set_plate_location(plate_id)
        location = db[:locations].where(:name => PLATE_LOCATION).first
        raise UnknownLocation, "The location #{PLATE_LOCATION} cannot be found in Sequencescape" unless location

        location_id = location[:id]
        db[:location_associations].insert(:locatable_id => plate_id, :location_id => location_id)
      end

      # @param [Integer] well_id
      # @param [Integer] study_id
      # @param [Time] date
      # Add a row in request unless it already exists for the well
      def set_request!(well_id, study_id, date)
        request = db[:requests].where({
          :asset_id => well_id,
          :initial_study_id => study_id
        }).first

        unless request
          db[:requests].insert({
            :asset_id => well_id,
            :initial_study_id => study_id,
            :sti_type => REQUEST_STI_TYPE,
            :state => REQUEST_STATE,
            :request_type_id => REQUEST_TYPE_ID,
            :created_at => date,
            :updated_at => date 
          })
        end
      end

      # @param [Integer] sample_id
      # @return [Integer]
      def study_id(sample_id)
        study = db[:study_samples].where(:sample_id => sample_id).order(:created_at).first 
        study[:study_id]
      end

      # Returns a the tag_id based on the type of the sample
      def get_tag_id(sample_id)
        tag_id = -1

        sample_type = db[:sample_metadata].select(:sample_type).where(
          :sample_id => sample_id).first

        if sample_type
          sample_type_value = sample_type[:sample_type]

          if sample_type_value.match(/\bDNA\b/)
            tag_id = -100
          elsif sample_type_value.match(/\bRNA\b/)
            tag_id = -101
          end
        end
        tag_id
      end
      private :get_tag_id

      # Update plate purpose in Sequencescape.
      # If the plate_uuid is not found in the database,
      # it means the order message has been received before 
      # the plate message. A PlateNotFoundInSequencescape exception 
      # is raised in that case. Otherwise, the plate is updated 
      # with the right plate_purpose_id for a stock plate.
      # @param [String] plate uuid
      # @param [Time] date 
      def update_plate_purpose_in_sequencescape(plate_uuid, date, plate_purpose_id)
        plate_id = plate_id_by_uuid(plate_uuid)
        db[:assets].where(:id => plate_id).update(
          :plate_purpose_id => plate_purpose_id,
          :updated_at => date
        ) 
      end

      # @param [String] uuid
      # @return [Integer]
      def plate_id_by_uuid(uuid)
        plate_uuid_data = db[:uuids].select(:resource_id).where(
          :external_id => uuid
        ).first

        raise PlateNotFoundInSequencescape, "The plate #{uuid} cannot be found in Sequencescape" unless plate_uuid_data
        plate_uuid_data[:resource_id]
      end

      # @param [Integer] plate_id
      # @return [Hash]
      # @example {"A1" => 1548, "A2" => 1549...}
      def location_wells(plate_id)
        db[:container_associations].select(
          :assets__id, :maps__description
        ).join(
          :assets, :id => :content_id
        ).join(
          :maps, :id => :map_id
        ).where(:container_id => plate_id).all.inject({}) do |m,e|
          m.merge({e[:description] => e[:id]})
        end
      end

      # Update the aliquots of a plate after a plate transfer
      # @param [Lims::Core::Laboratory::Plate] plate
      # @param [String] plate uuid
      # @param [Hash] sample uuids
      def update_aliquots_in_sequencescape(plate, plate_uuid, date, sample_uuids)
        plate_id = plate_id_by_uuid(plate_uuid)

        # wells is a hash associating a location to a well id
        wells = location_wells(plate_id) 

        # We save the plate wells data from the transfer
        plate.keys.each do |location|
          if sample_uuids.has_key?(location)
            sample_uuids[location].each do |sample_uuid|
              sample_resource_uuid = db[:uuids].select(:resource_id).where(
                :resource_type => SAMPLE,
                :external_id => sample_uuid
              ).first

              raise UnknownSample, "The sample #{sample_uuid} cannot be found in Sequencescape" unless sample_resource_uuid
              sample_id = sample_resource_uuid[:resource_id]
              tag_id = get_tag_id(sample_id)
              receptacle_id = wells[location]
              study_id = study_id(sample_id)

              aliquot = db[:aliquots].where({
                :receptacle_id => receptacle_id, 
                :sample_id => sample_id, 
                :tag_id => tag_id
              }).first 

              # The aliquot is added only if it doesn't exist yet
              unless aliquot
                set_request!(receptacle_id, study_id, date) 

                db[:aliquots].insert(
                  :receptacle_id => receptacle_id,
                  :sample_id => sample_id,
                  :study_id => study_id,
                  :created_at => date,
                  :updated_at => date,
                  :tag_id => tag_id
                )
              end
            end
          end
        end
      end

      # @param [String] plate_uuid
      # Delete the plate and all its references (wells, aliquots...)
      def delete_plate(plate_uuid)
        plate_id = plate_id_by_uuid(plate_uuid)
        well_ids = db[:container_associations].where(:container_id => plate_id).all.inject([]) do |m,e|
          m << e[:content_id]
        end

        db[:container_associations].where(:container_id => plate_id, :content_id => well_ids).delete
        db[:assets].where(:id => (well_ids + [plate_id])).delete
        db[:uuids].where(:external_id => plate_uuid).delete
        db[:aliquots].where(:receptacle_id => well_ids).delete
      end

      # @param [Hash] aliquot_locations
      # @example: {plate_uuid => [:A1, :B4]}
      # Delete all the aliquots in the location specified
      # in aliquot_locations.
      def delete_aliquots_in_sequencescape(aliquot_locations)
        aliquot_locations.each do |plate_uuid, locations|
          plate_id = plate_id_by_uuid(plate_uuid) 
          well_ids = db[:container_associations].select(
            :assets__id 
          ).join(
            :assets, 
            :id => :content_id
          ).join(
            :maps, 
            :id => :map_id
          ).where(:container_id => plate_id, :description => locations.map { |l| l.to_s }).all.inject([]) do |m,e|
            m << e[:id]
          end

          db[:aliquots].where(:receptacle_id => well_ids).delete
        end
      end

      # @param [Lims::LaboratoryApp::Labels::Labellable] labellable
      # @param [Time] date
      def set_barcode_to_a_plate(labellable, date)
        plate_id = plate_id_by_uuid(labellable.name)
        barcode = sanger_barcode(labellable)

        unless BARCODE_PREFIXES.map { |p| p.downcase }.include?(barcode[:prefix].downcase)
          raise InvalidBarcode, "#{barcode[:prefix]} is not a valid barcode prefix"
        end

        barcode_prefix_id = barcode_prefix_id(barcode[:prefix])
        plate_name = "Plate #{barcode[:number]}"

        db[:assets].where(:id => plate_id).update({
          :name => plate_name,
          :barcode => barcode[:number], 
          :barcode_prefix_id => barcode_prefix_id,
          :updated_at => date
        })
      end

      # @param [String] prefix
      # @return [Integer]
      # Return the prefix id. Create the prefix if
      # it does not exist yet.
      def barcode_prefix_id(prefix)
        barcode_prefix = db[:barcode_prefixes].where(:prefix => prefix).first
        return barcode_prefix[:id] if barcode_prefix

        db[:barcode_prefixes].insert(:prefix => prefix)
        return barcode_prefix_id(prefix)
      end
      private :barcode_prefix_id

      # @param [Lims::LaboratoryApp::Labels::Labellable] labellable
      # @return [Hash]
      # Return the first sanger barcode found in the labellable
      # The preceeding zeroes from the barcode are stripped for sequencescape.
      def sanger_barcode(labellable)
        labellable.each do |position, label|
          if label.type == SANGER_BARCODE_TYPE
            label.value.match(/^(\w{2})([0-9]*)\w$/)
            prefix = $1
            number = $2.to_i.to_s
            return {:prefix => prefix, :number => number} 
          end
        end
      end
      private :sanger_barcode

      # @param [String] plate_uuid
      # @param [Hash] location_samples
      # @param [Hash] swaps
      # @param [Time] date
      def swap_samples(plate_uuid, location_samples, swaps, date)
        plate_id = plate_id_by_uuid(plate_uuid)
        location_wells = location_wells(plate_id)

        location_wells.each do |location, well_id|
          sample_uuids = location_samples[location]
          next unless sample_uuids

          sample_uuids.each do |sample_uuid|
            old_sample_uuid = swaps.inverse[sample_uuid]
            next unless old_sample_uuid

            sample_resource_uuid = db[:uuids].where(:resource_type => SAMPLE, :external_id => sample_uuid).first 
            raise UnknownSample, "The sample #{sample_uuid} cannot be found in Sequencescape" unless sample_resource_uuid
            sample_id = sample_resource_uuid[:resource_id]

            old_sample_resource_uuid = db[:uuids].where(:resource_type => SAMPLE, :external_id => old_sample_uuid).first 
            raise UnknownSample, "The sample #{old_sample_uuid} cannot be found in Sequencescape" unless old_sample_resource_uuid
            old_sample_id = old_sample_resource_uuid[:resource_id]

            db[:aliquots].where(
              :receptacle_id => well_id, :sample_id => old_sample_id
            ).update(:sample_id => sample_id, :updated_at => date) 
          end
        end
      end
    end
  end 
end
