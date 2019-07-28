# == Schema Information
#
# Table name: storage_locations
#
#  id              :integer          not null, primary key
#  name            :string
#  address         :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organization_id :integer
#  latitude        :float
#  longitude       :float
#

class StorageLocation < ApplicationRecord
  require "csv"

  belongs_to :organization
  has_many :inventory_items, -> { includes(:item).order("items.name") },
           inverse_of: :storage_location
  has_many :donations, dependent: :destroy
  has_many :distributions, dependent: :destroy
  has_many :items, through: :inventory_items
  has_many :transfers_from, class_name: "Transfer",
                            inverse_of: :from,
                            foreign_key: :id,
                            dependent: :destroy
  has_many :transfers_to, class_name: "Transfer",
                          inverse_of: :to,
                          foreign_key: :id,
                          dependent: :destroy

  validates :name, :address, :organization, presence: true

  include Geocodable
  include Filterable
  scope :containing, ->(item_id) {
    joins(:inventory_items).where("inventory_items.item_id = ?", item_id)
  }
  scope :alphabetized, -> { order(:name) }
  scope :for_csv_export, ->(organization) { where(organization: organization) }

  def self.item_total(item_id)
    StorageLocation.select("quantity")
                   .joins(:inventory_items)
                   .where("inventory_items.item_id = ?", item_id)
                   .collect(&:quantity)
                   .reduce(:+)
  end

  def self.items_inventoried
    Item.joins(:storage_locations).select(:id, :name).group(:id, :name).order(name: :asc)
  end

  def item_total(item_id)
    inventory_items.select(:quantity).find_by(item_id: item_id).try(:quantity)
  end

  def size
    inventory_items.sum(:quantity)
  end

  def to_csv
    org = organization

    CSV.generate(headers: true) do |csv|
      csv << ["Quantity", "DO NOT CHANGE ANYTHING IN THIS ROW"]
      org.items.each do |item|
        csv << ["", item.name]
      end
    end
  end

  # NOTE: We should generalize this elsewhere -- Importable concern?
  def self.import_csv(csv, organization)
    csv.each do |row|
      loc = StorageLocation.new(row.to_hash)
      loc.organization_id = organization
      loc.save!
    end
  end

  # NOTE: We should generalize this elsewhere -- Importable concern?
  def self.import_inventory(filename, org, loc)
    current_org = Organization.find(org)
    adjustment = current_org.adjustments.create(storage_location_id: loc.to_i, comment: "Starting Inventory")
    # NOTE: this was originally headers: false; it may create buggy behavior
    CSV.parse(filename, headers: true) do |row|
      adjustment.line_items
                .create(quantity: row[0].to_i, item_id: current_org.items.find_by(name: row[1]))
    end
    adjustment.storage_location.increase_inventory(adjustment)
  end

  # FIXME: After this is stable, revisit how we do logging
  def increase_inventory(itemizable_array)
    itemizable_array = itemizable_array.to_a

    # This is, at least for now, how we log changes to the inventory made in this call
    log = {}
    # Iterate through each of the line-items in the moving box
    Item.reactivate(itemizable_array.map { |item_hash| item_hash[:item_id] })
    itemizable_array.each do |item_hash|
      # Locate the storage box for the item, or create a new storage box for it
      inventory_item = inventory_items.find_or_create_by!(item_id: item_hash[:item_id])
      # Increase the quantity-on-record for that item
      inventory_item.increment!(:quantity, item_hash[:quantity].to_i)
      # Record in the log that this has occurred
      log[item_hash[:item_id]] = "+#{item_hash[:quantity]}"
    end
    # log could be pulled from dirty AR stuff?
    # Save the final changes -- does this need to occur here?
    save
    # return log
    log
  end

  # TODO: re-evaluate this for optimization
  def decrease_inventory(itemizable_array)
    itemizable_array = itemizable_array.to_a

    # This is, at least for now, how we log changes to the inventory made in this call
    log = {}
    # This tracks items that have insufficient inventory counts to be reduced as much
    insufficient_items = []
    # Iterate through each of the line-items in the moving box
    itemizable_array.each do |item_hash|
      # Locate the storage box for the item, or create an empty storage box
      inventory_item = inventory_items.find_by(item_id: item_hash[:item_id]) || inventory_items.build
      # If we've got sufficient inventory in the storage box to fill the moving box, then continue
      next unless inventory_item.quantity < item_hash[:quantity]

      # Otherwise, we need to record that there was insufficient inventory on-hand
      insufficient_items << {
        item_id: item_hash[:item_id],
        item_name: item_hash[:name],
        quantity_on_hand: inventory_item.quantity,
        quantity_requested: item_hash[:quantity]
      }
    end

    # NOTE: Could this be handled by a validation instead?
    # If we found any insufficiencies
    unless insufficient_items.empty?
      # Raise this custom error with information about each of the items that showed insufficient
      # This bails out of the method!
      raise Errors::InsufficientAllotment.new(
        "Requested items exceed the available inventory",
        insufficient_items
      )
    end

    # Re-run through the items in the moving box again
    itemizable_array.each do |item_hash|
      # Look for the moving box for this item -- we know there is sufficient quantity this time
      # Raise AR:RNF if it fails to find it -- though that seems moot since it would have been
      # captured by the previous block.
      inventory_item = inventory_items.find_by(item_id: item_hash[:item_id])
      # Reduce the inventory box quantity
      inventory_item.decrement!(:quantity, item_hash[:quantity])
      # Record in the log that this has occurred
      log[item_hash[:item_id]] = "-#{item_hash[:quantity]}"
    end
    # log could be pulled from dirty AR stuff
    save!
    # return log
    log
  end

  def self.csv_export_headers
    ["Name", "Address", "Total Inventory"]
  end

  def csv_export_attributes
    [name, address, size]
  end
end
