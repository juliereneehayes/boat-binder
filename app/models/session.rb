class Session < ApplicationRecord
  module Policy
    OWNER_IDLE_TIMEOUT = 14.days
    OWNER_ABSOLUTE_LIFETIME = 30.days
    PRIVILEGED_IDLE_TIMEOUT = 12.hours
    PRIVILEGED_ABSOLUTE_LIFETIME = 7.days
    ACTIVITY_TOUCH_INTERVAL = 15.minutes

    module_function

    def idle_timeout_for(user)
      privileged?(user) ? PRIVILEGED_IDLE_TIMEOUT : OWNER_IDLE_TIMEOUT
    end

    def absolute_lifetime_for(user)
      privileged?(user) ? PRIVILEGED_ABSOLUTE_LIFETIME : OWNER_ABSOLUTE_LIFETIME
    end

    def privileged?(user)
      user.admin? || user.captain?
    end
    private_class_method :privileged?
  end

  belongs_to :user

  class << self
    def create_for!(user:, user_agent:, ip_address:, now: Time.current)
      user.sessions.create!(
        user_agent:,
        ip_address:,
        last_seen_at: now,
        expires_at: now + Policy.absolute_lifetime_for(user)
      )
    end

    def authenticate(session_id, now: Time.current, touch: true)
      session = includes(:user).find_by(id: session_id)
      return unless session

      unless session.valid_at?(now)
        session.destroy
        return
      end

      session.touch_activity!(now) if touch
      session
    end
  end

  def valid_at?(now = Time.current)
    persisted? && !destroyed? && user&.active? && last_seen_at.present? && expires_at.present? &&
      last_seen_at > now - Policy.idle_timeout_for(user) && expires_at > now
  end

  def touch_activity!(now = Time.current)
    return unless last_seen_at <= now - Policy::ACTIVITY_TOUCH_INTERVAL

    update_column(:last_seen_at, now)
  end
end
