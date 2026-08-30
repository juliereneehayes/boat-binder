module Admin
  class AccountExportRequestsController < ApplicationController
    REVIEW_ACTIONS = %w[verify_recipient verify_scope approve decline fulfill].freeze

    before_action :require_admin!
    before_action :set_export_request, only: %i[show update]

    def index
      @export_requests = AccountExportRequest.includes(:account, :requester).recent_first
    end

    def show
    end

    def update
      case review_action_param
      when "verify_recipient"
        @export_request.verify_recipient!(reviewer: current_user)
      when "verify_scope"
        @export_request.verify_scope!(reviewer: current_user)
      when "approve"
        @export_request.approve!(reviewer: current_user)
      when "decline"
        @export_request.decline!(reviewer: current_user)
      when "fulfill"
        @export_request.fulfill!(reviewer: current_user)
      end

      redirect_to admin_account_export_request_path(@export_request),
        notice: "Export request updated.",
        status: :see_other
    rescue ActiveRecord::RecordInvalid
      render :show, status: :unprocessable_entity
    end

    private

    def set_export_request
      @export_request = AccountExportRequest.includes(
        :account,
        :requester,
        :recipient_verified_by,
        :scope_verified_by,
        :decided_by,
        :fulfilled_by
      ).find(params[:id])
    end

    def review_action_param
      value = params.require(:review_action)
      return value if value.is_a?(String) && REVIEW_ACTIONS.include?(value)

      raise ActionController::ParameterMissing, :review_action
    end
  end
end
