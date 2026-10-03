class SecurityAuditEvent < ApplicationRecord
  # Application-layer guardrails only. Deliberate raw SQL, unscoped mutations,
  # bulk insert/upsert APIs, and database-owner access remain outside this scope.
  module AppendOnlyRelation
    MUTATION_ERROR = "SecurityAuditEvent is append-only"

    def delete_all(*)
      raise ActiveRecord::ReadOnlyRecord, MUTATION_ERROR
    end

    def destroy_all(*)
      raise ActiveRecord::ReadOnlyRecord, MUTATION_ERROR
    end

    def touch_all(*)
      raise ActiveRecord::ReadOnlyRecord, MUTATION_ERROR
    end

    def update_all(*)
      raise ActiveRecord::ReadOnlyRecord, MUTATION_ERROR
    end

    def update_counters(*)
      raise ActiveRecord::ReadOnlyRecord, MUTATION_ERROR
    end
  end

  OUTCOMES = %w[succeeded failed denied].freeze
  CHANGED_FIELDS = %w[active password role].freeze
  ACTION_FORMAT = /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/
  TARGET_TYPE_FORMAT = /\A[A-Z][A-Za-z0-9:]*\z/

  # These associations resolve historical scalar identifiers when the source
  # rows still exist; missing historical rows are valid and resolve to nil.
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :account, optional: true

  default_scope { extending(AppendOnlyRelation) }
  scope :for_account, ->(account) { where(account:) }

  validates :action, presence: true, format: { with: ACTION_FORMAT }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :request_id, length: { maximum: 255 }, allow_nil: true
  validates :target_type, format: { with: TARGET_TYPE_FORMAT }, allow_nil: true
  validate :target_reference_is_complete
  validate :changed_fields_are_names_only

  def readonly?
    persisted?
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, AppendOnlyRelation::MUTATION_ERROR if persisted?

    super
  end

  private

  def target_reference_is_complete
    return if target_type.present? == target_id.present?

    errors.add(:target, "type and id must be provided together")
  end

  def changed_fields_are_names_only
    unless changed_fields.is_a?(Array)
      errors.add(:changed_fields, "must be an array")
      return
    end

    return if changed_fields.all? { |field| field.is_a?(String) && field.in?(CHANGED_FIELDS) }

    errors.add(:changed_fields, "must contain only approved semantic field names")
  end
end
