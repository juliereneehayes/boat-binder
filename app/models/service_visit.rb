class ServiceVisit < ApplicationRecord
  ALLOWED_PHOTO_CONTENT_TYPES = %w[
    image/jpeg
    image/png
    image/webp
  ].freeze

  DEFAULT_INSPECTION_LABELS = [
    "Hull",
    "Bilge",
    "Shore power",
    "Dock lines",
    "Interior",
    "Systems",
    "Batteries",
    "Engine room",
    "Safety equipment"
  ].freeze

  belongs_to :asset
  belongs_to :performed_by_user, class_name: "User"
  belongs_to :follow_up_completed_by_user, class_name: "User", optional: true
  has_many :service_visit_engine_readings, dependent: :destroy
  has_many :service_visit_inspection_checks, dependent: :destroy
  has_many :service_visit_battery_checks, dependent: :destroy
  has_many :follow_up_events, -> { order(:created_at, :id) },
    class_name: "ServiceVisitFollowUpEvent", dependent: :destroy, inverse_of: :service_visit
  has_many_attached :photos

  validates :visit_date, presence: true
  validates :engine_hours, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validates :summary, :condition_notes, :follow_up_notes, length: { maximum: 2_000 }
  validate :photos_are_safe_uploads
  validate :follow_up_completion_is_consistent

  scope :recent, -> { order(visit_date: :desc, created_at: :desc) }
  scope :with_open_follow_up, -> { where(follow_up_needed: true, follow_up_completed_at: nil) }

  def summary_recipient_email
    asset.account.transactional_recipient_email
  end

  def build_workflow_defaults
    build_default_engine_readings
    build_default_inspection_checks
    build_default_battery_checks
  end

  def follow_up_open?
    follow_up_needed? && follow_up_completed_at.blank?
  end

  def follow_up_completed?
    follow_up_needed? && follow_up_completed_at.present?
  end

  def complete_follow_up!(by:)
    transitioned = false

    with_lock do
      if follow_up_open?
        event = follow_up_events.create!(action: "completed", actor_user: by)
        update!(follow_up_completed_at: event.created_at, follow_up_completed_by_user: by)
        transitioned = true
      end
    end

    transitioned
  end

  def reopen_follow_up!(by:)
    transitioned = false

    with_lock do
      if follow_up_completed?
        follow_up_events.create!(action: "reopened", actor_user: by)
        update!(follow_up_completed_at: nil, follow_up_completed_by_user: nil)
        transitioned = true
      end
    end

    transitioned
  end

  def ordered_engine_readings
    service_visit_engine_readings.sort_by { |reading| [ reading.asset_engine.position, reading.asset_engine.name ] }
  end

  def ordered_inspection_checks
    service_visit_inspection_checks.sort_by { |check| [ check.position, check.id || 0 ] }
  end

  def ordered_battery_checks
    service_visit_battery_checks.sort_by { |check| check.asset_battery.name }
  end

  private

  def follow_up_completion_is_consistent
    completion_fields_match = follow_up_completed_at.present? == follow_up_completed_by_user_id.present?
    return if completion_fields_match && (follow_up_completed_at.blank? || follow_up_needed?)

    errors.add(:base, "Follow-up completion state is invalid")
  end

  def photos_are_safe_uploads
    return unless photos.attached?

    invalid_photos = photos.reject do |photo|
      ALLOWED_PHOTO_CONTENT_TYPES.include?(photo.blob.content_type.to_s)
    end

    return if invalid_photos.none?

    errors.add(:photos, "must be JPEG, PNG, or WEBP images")
    invalid_photos.each(&:purge)
  end

  def build_default_engine_readings
    asset.ensure_default_engines!

    asset.active_engines.each do |engine|
      next if service_visit_engine_readings.any? { |reading| reading.asset_engine == engine }

      service_visit_engine_readings.build(asset_engine: engine)
    end
  end

  def build_default_inspection_checks
    DEFAULT_INSPECTION_LABELS.each_with_index do |label, index|
      next if service_visit_inspection_checks.any? { |check| check.label == label }

      service_visit_inspection_checks.build(label: label, position: index + 1)
    end
  end

  def build_default_battery_checks
    asset.active_batteries.each do |battery|
      next if service_visit_battery_checks.any? { |check| check.asset_battery == battery }

      service_visit_battery_checks.build(asset_battery: battery)
    end
  end
end
