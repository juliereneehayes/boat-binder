module Authentication
  extend ActiveSupport::Concern

  GENERIC_LOGIN_FAILURE_MESSAGE = "We couldn't sign you in with those credentials. Please contact an administrator if you believe this is a mistake."

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      session = Session.authenticate(cookies.signed[:session_id])
      clear_session_cookie if session.nil? && cookies[:session_id].present?
      session
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def establish_session_after_primary_authentication(user, session_redirect:)
      if Mfa::Policy.required_for_sign_in?(user)
        user.begin_mfa_enrollment! unless user.mfa_enrolled? || user.mfa_enrollment_pending?
        Mfa::Challenge.issue!(cookies:, user:)
        user.mfa_enrolled? ? new_mfa_challenge_path : settings_mfa_enrollment_path
      else
        Mfa::Challenge.clear!(cookies)
        start_new_session_for(user)
        session_redirect.respond_to?(:call) ? session_redirect.call : session_redirect
      end
    end

    # Low-level Session creation for callers that have already passed the MFA
    # policy gate or have just completed MFA successfully.
    def start_new_session_for(user)
      Session.create_for!(user:, user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed[:session_id] = {
          value: session.id,
          expires: session.expires_at,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?
        }
      end
    end

    def terminate_session
      Current.session&.destroy
      Current.session = nil
      clear_session_cookie
    end

    def clear_session_cookie
      cookies.delete(:session_id, httponly: true, same_site: :lax, secure: Rails.env.production?)
    end
end
