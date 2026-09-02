module Admin
  class UsersController < ApplicationController
    INVITATION_DELIVERY_FAILURE_MESSAGE = "User was created, but the invitation email could not be sent. Check email configuration."
    INVITATION_RESEND_FAILURE_MESSAGE = "Invitation email could not be sent. Check email configuration."
    INVITATION_RESEND_UNAVAILABLE_MESSAGE = "Invitation can only be resent for pending invited users."

    before_action :require_admin!
    before_action :set_user, only: %i[edit update resend_invitation]
    before_action :set_accounts, only: %i[new create edit update]

    def index
      @users = User.includes(account_memberships: :account).order(:role, :email_address)
    end

    def new
      @send_invitation = true
      @active_checked = true
      @user = User.new(role: "owner", active: true)
    end

    def create
      @user = User.new(user_params)
      @active_checked = active_checkbox_checked?
      assign_admin_managed_user_attributes(@user)
      prepare_invitation if send_invitation?

      if save_user_with_memberships
        if send_invitation?
          if deliver_invitation
            redirect_to admin_users_path, notice: "User invited."
          else
            redirect_to admin_users_path, alert: INVITATION_DELIVERY_FAILURE_MESSAGE
          end
        else
          redirect_to admin_users_path, notice: "User added."
        end
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      @user.assign_attributes(user_params)
      assign_admin_managed_user_attributes(@user)

      if save_user_with_memberships
        redirect_to admin_users_path, notice: "User updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def resend_invitation
      unless @user.invitation_pending?
        redirect_to admin_users_path, alert: INVITATION_RESEND_UNAVAILABLE_MESSAGE
        return
      end

      if resend_pending_invitation
        redirect_to admin_users_path, notice: "Invitation resent."
      else
        redirect_to admin_users_path, alert: INVITATION_RESEND_FAILURE_MESSAGE
      end
    end

    private

    def set_user
      @user = User.find(params[:id])
    end

    def set_accounts
      @accounts = account_access_scope
    end

    def user_params
      permitted = params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
      if @user&.persisted? && permitted[:password].blank? && permitted[:password_confirmation].blank?
        permitted = permitted.except(:password, :password_confirmation)
      end
      permitted
    end

    def assign_admin_managed_user_attributes(user)
      requested_role = params.dig(:user, :role)
      if requested_role.present?
        if User::ROLES.include?(requested_role)
          user.role = requested_role
        else
          @invalid_role_value = requested_role
        end
      end

      return unless params.dig(:user, :active)

      user.active = ActiveModel::Type::Boolean.new.cast(params.dig(:user, :active))
    end

    def send_invitation?
      return @send_invitation unless @send_invitation.nil?

      @send_invitation = if params.dig(:user, :send_invitation).nil?
        @user.new_record? && params.dig(:user, :password).blank?
      else
        ActiveModel::Type::Boolean.new.cast(params.dig(:user, :send_invitation))
      end
    end

    def active_checkbox_checked?
      return true unless params.key?(:user)
      return true unless params[:user].key?(:active)

      ActiveModel::Type::Boolean.new.cast(params.dig(:user, :active))
    end

    def prepare_invitation
      @user.active = false
      @user.invitation_sent_at = Time.current
      @user.invitation_accepted_at = nil
      @user.password = nil
      @user.password_confirmation = nil
      @user.password_digest = nil
    end

    def deliver_invitation
      UserInvitationsMailer.invite(@user).deliver_now
      Rails.logger.info("Invitation email delivered for user_id=#{@user.id}")
      true
    rescue *ApplicationMailer::DELIVERY_ERRORS => error
      Rails.logger.error(
        "Invitation email delivery failed for user_id=#{@user.id}: #{error.class}: #{error.message}"
      )
      false
    end

    def resend_pending_invitation
      previous_invitation_state = invitation_resend_state

      prepare_invitation
      unless @user.save
        restore_invitation_state(previous_invitation_state)
        return false
      end

      return true if deliver_invitation

      restore_invitation_state(previous_invitation_state)
      false
    end

    def invitation_resend_state
      @user.slice(:active, :invitation_sent_at, :invitation_accepted_at, :password_digest)
    end

    def restore_invitation_state(state)
      @user.assign_attributes(state)

      if @user.save
        @user.reload
      else
        Rails.logger.error(
          "Invitation resend state restore failed for user_id=#{@user.id}: #{@user.errors.full_messages.to_sentence}"
        )
      end
    end

    def save_user_with_memberships
      saved = false

      User.transaction do
        account_access_valid = owner_account_access_valid?
        lock_membership_accounts! if account_access_valid
        user_valid = admin_managed_user_valid?

        if user_valid && account_access_valid && @user.save && sync_account_memberships
          saved = true
        else
          raise ActiveRecord::Rollback
        end
      end

      saved
    end

    # Account locks make seat validation and membership writes one serialized operation.
    # The stable ID order prevents two multi-Account Admin updates from deadlocking.
    def lock_membership_accounts!
      account_ids = @user.account_memberships.active.pluck(:account_id)
      account_ids.concat(@submitted_account_ids || []) if @user.owner?

      Account.where(id: account_ids.uniq).order(:id).lock.load
    end

    def admin_managed_user_valid?
      @user.valid?
      if @invalid_role_value.present? && @user.errors[:role].blank?
        @user.errors.add(:role, "is not included in the list")
      end
      @user.errors.empty?
    end

    def sync_account_memberships
      unless @user.owner?
        @user.account_memberships.active.update_all(active: false, updated_at: Time.current)
        return true
      end

      @submitted_account_ids.each do |account_id|
        membership = @user.account_memberships.find_or_initialize_by(account_id: account_id)
        membership.access_level = @submitted_account_access_levels.fetch(account_id)
        membership.active = true
        unless membership.save
          @user.errors.add(:base, "Account access could not be updated.")
          membership.errors.full_messages.each { |message| @user.errors.add(:base, message) }
          return false
        end
      end

      @user.account_memberships.where.not(account_id: @submitted_account_ids)
        .update_all(active: false, updated_at: Time.current)
      true
    end

    def owner_account_access_valid?
      return true unless @user.owner?
      return @owner_account_access_valid unless @owner_account_access_valid.nil?

      @owner_account_access_valid = true
      selected_account_ids = parse_selected_account_ids
      submitted_access_levels = parse_submitted_access_levels
      referenced_account_ids = (selected_account_ids + submitted_access_levels.keys).uniq
      available_account_ids = account_access_scope.where(id: referenced_account_ids).pluck(:id)

      if referenced_account_ids.sort != available_account_ids.sort
        add_account_access_error("includes an unavailable account")
      end

      @submitted_account_ids = selected_account_ids & available_account_ids
      existing_access_levels = if @user.persisted?
        @user.account_memberships.where(account_id: @submitted_account_ids).pluck(:account_id, :access_level).to_h
      else
        {}
      end
      @submitted_account_access_levels = @submitted_account_ids.index_with do |account_id|
        submitted_access_levels.fetch(
          account_id,
          existing_access_levels.fetch(account_id, AccountMembership::DEFAULT_ACCESS_LEVEL)
        )
      end

      @owner_account_access_valid
    end

    def parse_selected_account_ids
      values = params.dig(:user, :account_ids)
      return [] if values.nil?

      unless values.is_a?(Array)
        add_account_access_error("has an invalid account selection")
        return []
      end

      values.compact_blank.filter_map { |value| parse_account_id(value) }.uniq
    end

    def parse_submitted_access_levels
      raw_levels = params.dig(:user, :account_access_levels)
      return {} if raw_levels.nil?

      levels = if raw_levels.is_a?(ActionController::Parameters)
        raw_levels.to_unsafe_h
      elsif raw_levels.is_a?(Hash)
        raw_levels
      else
        add_account_access_error("has invalid access-level data")
        return {}
      end

      levels.each_with_object({}) do |(raw_account_id, raw_access_level), parsed_levels|
        account_id = parse_account_id(raw_account_id)
        next unless account_id

        access_level = raw_access_level.to_s
        if AccountMembership::ACCESS_LEVELS.include?(access_level)
          parsed_levels[account_id] = access_level
        else
          add_account_access_error("has an invalid access level")
        end
      end
    end

    def parse_account_id(value)
      account_id = value.to_s
      unless /\A[1-9]\d*\z/.match?(account_id)
        add_account_access_error("has an invalid account selection")
        return
      end

      Account.type_for_attribute(Account.primary_key).serialize(Integer(account_id, 10))
    rescue ActiveModel::RangeError
      add_account_access_error("has an invalid account selection")
      nil
    end

    def add_account_access_error(message)
      @owner_account_access_valid = false
      @user.errors.add(:base, "Owner account access #{message}.")
    end

    def account_access_scope
      scoped_accounts.active.ordered
    end
  end
end
