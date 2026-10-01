class EmailChangesController < ApplicationController
  FAILURE_MESSAGE = "We couldn't request that email change. Check the details and try again."
  DELIVERY_FAILURE_MESSAGE = "We couldn't send the verification email. Please try again."
  THROTTLED_MESSAGE = "Try again later."
  RATE_LIMIT_KEY_PURPOSE = "email-change-authenticated-user-rate-limit"
  RATE_LIMIT_STORE_OVERRIDE_KEY = :email_changes_controller_rate_limit_store
  TOKEN_ROTATION_INCREMENT = Rational(1, 1_000_000)
  Rotation = Data.define(:previous_email, :previous_requested_at, :pending_email, :requested_at)

  class RateLimitStore
    def increment(...)
      EmailChangesController.rate_limit_store.increment(...)
    end
  end

  private_constant :RATE_LIMIT_STORE_OVERRIDE_KEY, :RateLimitStore
  RATE_LIMIT_STORE = RateLimitStore.new

  class << self
    def rate_limit_store
      ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY] || Rails.cache
    end

    def with_rate_limit_store(store)
      had_previous_store = ActiveSupport::IsolatedExecutionState.key?(RATE_LIMIT_STORE_OVERRIDE_KEY)
      previous_store = ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY]
      ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY] = store
      yield
    ensure
      if had_previous_store
        ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY] = previous_store
      else
        ActiveSupport::IsolatedExecutionState.delete(RATE_LIMIT_STORE_OVERRIDE_KEY)
      end
    end
  end

  rate_limit to: 5, within: 15.minutes, only: :create, name: "user",
    by: :authenticated_user_rate_limit_key,
    store: RATE_LIMIT_STORE,
    with: :throttled_email_change

  def create
    unless Current.user.authenticate(email_change_params[:current_password])
      return render_settings_error(FAILURE_MESSAGE)
    end

    rotation = rotate_pending_email
    return render_settings_validation_errors unless rotation

    deliver_verification
    redirect_to settings_path, notice: "Check the new email address for a verification link.", status: :see_other
  rescue *ApplicationMailer::DELIVERY_ERRORS => error
    restore_previous_email_change(rotation) if rotation
    Rails.logger.error(
      "Email change verification delivery failed for " \
      "user_id=#{Current.user.id} exception_class=#{error.class}"
    )
    render_settings_error(DELIVERY_FAILURE_MESSAGE)
  end

  private

  def email_change_params
    params.require(:email_change).permit(:email_address, :current_password)
  end

  def authenticated_user_rate_limit_key
    EmailRateLimitKey.call(Current.user.id.to_s, purpose: RATE_LIMIT_KEY_PURPOSE)
  end

  def throttled_email_change
    redirect_to settings_path, alert: THROTTLED_MESSAGE, status: :see_other
  end

  def rotate_pending_email
    Current.user.with_lock do
      previous_email = Current.user.pending_email_address
      previous_requested_at = Current.user.email_change_requested_at
      next_requested_at = previous_requested_at && previous_requested_at + TOKEN_ROTATION_INCREMENT
      requested_at = [ Time.current, next_requested_at ].compact.max

      Current.user.assign_attributes(
        pending_email_address: email_change_params[:email_address],
        email_change_requested_at: requested_at
      )
      next unless Current.user.save

      Rotation.new(
        previous_email:,
        previous_requested_at:,
        pending_email: Current.user.pending_email_address,
        requested_at: Current.user.reload.email_change_requested_at
      )
    end
  end

  def deliver_verification
    # Silence mailer logging so the tokenized URL and recipient are not emitted.
    ActionMailer::Base.logger.silence(Logger::FATAL) do
      EmailChangesMailer.verify(Current.user).deliver_now
    end
  end

  def restore_previous_email_change(rotation)
    Current.user.with_lock do
      Current.user.reload
      next unless Current.user.pending_email_address == rotation.pending_email
      next unless Current.user.email_change_requested_at == rotation.requested_at

      restored = Current.user.update(
        pending_email_address: rotation.previous_email,
        email_change_requested_at: rotation.previous_requested_at
      )
      Current.user.update!(pending_email_address: nil, email_change_requested_at: nil) unless restored
    end
  end

  def render_settings_validation_errors
    message = if Current.user.errors.of_kind?(:pending_email_address, :taken)
      FAILURE_MESSAGE
    else
      messages = Current.user.errors.full_messages_for(:pending_email_address)
      messages += Current.user.errors.full_messages_for(:email_change_requested_at)
      messages.to_sentence.presence || FAILURE_MESSAGE
    end
    Current.user.reload
    Current.user.errors.clear
    render_settings_error(message)
  end

  def render_settings_error(message)
    @user = Current.user
    @active_sessions = Current.user.active_sessions
    @email_change_error = message
    @submitted_email_address = email_change_params[:email_address]
    render "settings/show", status: :unprocessable_entity
  end
end
