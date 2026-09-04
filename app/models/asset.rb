class Asset < ApplicationRecord
  ASSET_TYPES = %w[vessel home pet audit other].freeze
  PRIMARY_PHOTO_CONTENT_TYPES = %w[
    image/jpeg
    image/png
    image/webp
  ].freeze
  PRIMARY_PHOTO_MAX_SIZE = 10.megabytes
  PRIMARY_PHOTO_CONTENT_TYPE_ERROR = "must be a JPEG, PNG, or WEBP image"
  PRIMARY_PHOTO_SIZE_ERROR = "must be 10 MB or smaller"

  belongs_to :account
  has_many :service_visits, dependent: :destroy
  has_many :reminders, dependent: :destroy
  has_many :binder_notes, dependent: :destroy
  has_many :documents, dependent: :destroy
  has_many :asset_engines, dependent: :destroy
  has_many :asset_batteries, dependent: :destroy
  has_one_attached :primary_photo

  before_validation :normalize_text_fields
  before_validation :ensure_slug

  validates :asset_type, inclusion: { in: ASSET_TYPES }
  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { scope: [ :account_id, :asset_type ] }
  validates :slug, presence: true, uniqueness: true
  validates :make, :model, :marina, :slip, :registration_number, length: { maximum: 120 }
  validates :year, numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: Date.current.year + 1 }, allow_blank: true
  validates :length, numericality: { greater_than: 0 }, allow_blank: true
  validates :registration_number, uniqueness: { scope: :account_id }, allow_blank: true
  validate :primary_photo_is_safe_upload

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :vessels, -> { where(asset_type: "vessel") }
  scope :ordered, -> { order(:name) }
  scope :search, ->(query) {
    next all if query.blank?

    query.to_s.squish.split.reduce(left_outer_joins(account: :contacts).distinct) do |scope, term|
      normalized_query = "%#{sanitize_sql_like(term)}%"
      scope.where(
        "assets.name ILIKE :query OR accounts.name ILIKE :query OR contacts.name ILIKE :query OR contacts.email ILIKE :query OR assets.marina ILIKE :query OR assets.slip ILIKE :query",
        query: normalized_query
      )
    end
  }

  def self.primary_photo_upload_error(upload)
    return if upload.blank?

    detected_content_type = primary_photo_upload_content_type(upload)

    return PRIMARY_PHOTO_CONTENT_TYPE_ERROR unless PRIMARY_PHOTO_CONTENT_TYPES.include?(detected_content_type)
    PRIMARY_PHOTO_SIZE_ERROR if primary_photo_upload_size(upload).to_i > PRIMARY_PHOTO_MAX_SIZE
  end

  def to_param
    slug
  end

  def owner_name
    owner_contact&.name || account.name
  end

  def owner_contact
    account.contacts.find { |contact| contact.role.to_s.downcase.include?("owner") }
  end

  def primary_contact
    owner_contact || account.contacts.first
  end

  def last_visit
    service_visits.recent.first
  end

  def next_reminder
    reminders.upcoming.first
  end

  def overdue_reminders
    reminders.pending.where("due_date < ?", account_today).order(:due_date)
  end

  def open_follow_up_visits
    service_visits.with_open_follow_up.recent
  end

  def display_model
    [ year, make, model ].compact_blank.join(" ")
  end

  def location_label
    [ marina, slip.present? ? "Slip #{slip}" : nil ].compact.join(", ").presence || "Location not set"
  end

  def active_engines
    asset_engines.active.ordered
  end

  def active_batteries
    asset_batteries.active.ordered
  end

  def ensure_default_engines!
    default_engines.each do |name, position|
      asset_engines.find_or_create_by!(name: name) do |engine|
        engine.position = position
        engine.active = true
      end
    end
  end

  def status_label
    return "Inactive" unless active?
    return "Needs attention" if overdue_reminders.exists? || open_follow_up_visits.exists?
    return "Scheduled" if next_reminder.present?

    "Clear"
  end

  def status_tone
    return :neutral unless active?
    return :urgent if overdue_reminders.exists? || open_follow_up_visits.exists?
    return :warning if next_reminder.present?

    :success
  end

  private

  def default_engines
    { "Port" => 1, "Starboard" => 2 }
  end

  def account_today
    zone = Time.find_zone(account.time_zone) || Time.zone

    Time.use_zone(zone) { Time.zone.today }
  end

  def primary_photo_is_safe_upload
    return unless primary_photo.attached?

    blob = primary_photo.blob
    unsafe_upload = false

    unless PRIMARY_PHOTO_CONTENT_TYPES.include?(blob.content_type.to_s)
      errors.add(:primary_photo, PRIMARY_PHOTO_CONTENT_TYPE_ERROR)
      unsafe_upload = true
    end

    if blob.byte_size > PRIMARY_PHOTO_MAX_SIZE
      errors.add(:primary_photo, PRIMARY_PHOTO_SIZE_ERROR)
      unsafe_upload = true
    end

    primary_photo.purge if unsafe_upload
  end

  def self.primary_photo_upload_size(upload)
    return upload.size if upload.respond_to?(:size)
    return upload.tempfile.size if upload.respond_to?(:tempfile) && upload.tempfile

    0
  end
  private_class_method :primary_photo_upload_size

  def self.primary_photo_upload_content_type(upload)
    io = primary_photo_upload_io(upload)

    return Marcel::MimeType.for(name: primary_photo_upload_filename(upload), declared_type: upload.content_type) unless io

    current_position = io.pos if io.respond_to?(:pos)
    io.rewind if io.respond_to?(:rewind)

    Marcel::MimeType.for(
      io,
      name: primary_photo_upload_filename(upload),
      declared_type: upload.content_type
    )
  ensure
    if io && current_position && io.respond_to?(:seek)
      io.seek(current_position)
    elsif io&.respond_to?(:rewind)
      io.rewind
    end
  end
  private_class_method :primary_photo_upload_content_type

  def self.primary_photo_upload_io(upload)
    return upload.tempfile if upload.respond_to?(:tempfile) && upload.tempfile

    upload if upload.respond_to?(:read)
  end
  private_class_method :primary_photo_upload_io

  def self.primary_photo_upload_filename(upload)
    return upload.original_filename if upload.respond_to?(:original_filename)

    upload.path if upload.respond_to?(:path)
  end
  private_class_method :primary_photo_upload_filename

  def normalize_text_fields
    %i[name make model marina slip registration_number notes].each do |attribute|
      value = public_send(attribute)
      next unless value.respond_to?(:squish)

      normalized_value = value.squish
      normalized_value = nil if normalized_value.blank? && attribute == :registration_number
      public_send("#{attribute}=", normalized_value)
    end
  end

  def ensure_slug
    return if name.blank? || (slug.present? && !will_save_change_to_name?)

    base_slug = name.parameterize.presence || "vessel"
    candidate = base_slug
    suffix = 2

    while self.class.where(slug: candidate).where.not(id: id).exists?
      candidate = "#{base_slug}-#{suffix}"
      suffix += 1
    end

    self.slug = candidate
  end
end
