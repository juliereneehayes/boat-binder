class AccountExportRequestsController < ApplicationController
  DUPLICATE_MESSAGE = "An Account export request is already open."
  SUCCESS_MESSAGE = "Your Account export request was submitted for review."

  before_action :require_owner!

  def create
    access = Billing::OwnerAccountAccessResolver.call(
      user: current_user,
      account_reference: account_reference_param
    )
    recovery = Billing::OwnerLifecycleRecovery.new(
      account: access.account,
      membership: access.membership,
      now: Time.current
    )
    unless recovery.export_available?
      deny_access!
      return
    end

    AccountExportRequest.create!(
      account: access.account,
      requester: current_user,
      lifecycle_context: recovery.export_context
    )
    redirect_to root_path, notice: SUCCESS_MESSAGE, status: :see_other
  rescue Billing::OwnerAccountAccessResolver::ResolutionError,
    ActionController::ParameterMissing
    deny_access!
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to root_path, alert: DUPLICATE_MESSAGE, status: :see_other
  end

  private

  def require_owner!
    deny_access! unless owner_user?
  end

  def account_reference_param
    reference = params.require(:account_reference)
    return reference if reference.is_a?(String)

    raise ActionController::ParameterMissing, :account_reference
  end
end
