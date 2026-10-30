class VesselAccessInformation < ApplicationRecord
  MAX_RESTRICTED_DETAILS_LENGTH = 10_000

  self.table_name = "vessel_access_information"

  belongs_to :vessel,
    -> { vessels },
    class_name: "Asset",
    foreign_key: :asset_id,
    inverse_of: :vessel_access_information

  encrypts :restricted_details
  attr_readonly :asset_id

  delegate :account, :account_id, to: :vessel

  validates :asset_id, uniqueness: true
  validates :restricted_details, presence: true, length: { maximum: MAX_RESTRICTED_DETAILS_LENGTH }
  validate :vessel_asset_type

  private

  def vessel_asset_type
    errors.add(:vessel, "must be a Vessel") if vessel.present? && vessel.asset_type != "vessel"
  end
end
