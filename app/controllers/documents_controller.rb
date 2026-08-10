class DocumentsController < ApplicationController
  DocumentFileAttachmentError = Class.new(StandardError)
  DOCUMENT_ATTRIBUTE_KEYS = %i[title document_type notes].freeze
  DOCUMENT_RELATIONSHIP_KEYS = %i[account_id asset_id].freeze

  before_action :set_vessel, only: %i[new create]
  before_action :require_document_write_access!, only: %i[new create]
  before_action :set_document, only: %i[show edit update destroy]
  before_action :require_existing_document_write_access!, only: %i[edit update destroy]
  before_action :set_form_collections, only: %i[new create edit update]

  def index
    @documents = scoped_documents.with_attached_file.includes(:account, :asset).order(created_at: :desc)
  end

  def show
  end

  def new
    @document = if @vessel
      @vessel.documents.new(account: @vessel.account, document_type: "photo")
    else
      Document.new(document_type: "registration")
    end
  end

  def create
    file_upload = document_file_upload
    @document = if @vessel
      @vessel.documents.new(document_attribute_params)
    else
      Document.new(document_attribute_params)
    end
    return unless assign_document_relationships(@document, template: :new)

    if (file_error = Document.file_upload_error(file_upload))
      render_document_form_with_file_error(@document, file_error, :new)
      return
    end

    ActiveRecord::Base.transaction do
      @document.save!
      attach_document_file!(@document, file_upload) if file_upload.present?
    end

    redirect_to after_create_path, notice: "Document uploaded."
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  rescue ActiveStorage::IntegrityError, DocumentFileAttachmentError => error
    Rails.logger.error("Document file attachment failed for create: #{error.class}: #{error.message}")
    render_document_form_with_file_error(@document, "could not be attached. Please try again.", :new)
  end

  def edit
  end

  def update
    file_upload = document_file_upload
    @document.assign_attributes(document_attribute_params)
    return unless assign_document_relationships(@document, template: :edit)

    if (file_error = Document.file_upload_error(file_upload))
      render_document_form_with_file_error(@document, file_error, :edit)
      return
    end

    ActiveRecord::Base.transaction do
      @document.save!
      attach_document_file!(@document, file_upload) if file_upload.present?
    end

    if @document.asset&.asset_type == "vessel"
      redirect_to vessel_path(@document.asset, anchor: "documents"), notice: "Document updated."
    else
      redirect_to document_path(@document), notice: "Document updated."
    end
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_entity
  rescue ActiveStorage::IntegrityError, DocumentFileAttachmentError => error
    Rails.logger.error("Document file attachment failed for update: #{error.class}: #{error.message}")
    render_document_form_with_file_error(@document, "could not be attached. Please try again.", :edit)
  end

  def destroy
    fallback_vessel = @document.asset if @document.asset&.asset_type == "vessel"
    @document.file.purge if @document.file.attached?
    @document.destroy!

    redirect_to fallback_location(fallback_vessel), notice: "Document removed."
  end

  private

  def set_vessel
    @vessel = scoped_vessels.find_by!(slug: params[:vessel_id]) if params[:vessel_id].present?
  end

  def set_document
    @document = scoped_documents.find(params[:id])
  end

  def document_request_params
    @document_request_params ||= params.require(:document)
  end

  def document_attribute_params
    @document_attribute_params ||= document_request_params
      .slice(*DOCUMENT_ATTRIBUTE_KEYS)
      .permit(*DOCUMENT_ATTRIBUTE_KEYS)
  end

  def document_file_upload
    document_request_params[:file]
  end

  def document_relationship_params
    @document_relationship_params ||= document_request_params.slice(*DOCUMENT_RELATIONSHIP_KEYS)
  end

  def set_form_collections
    @accounts = manageable_accounts.active.includes(:vessel_assets).ordered
    @vessels = manageable_vessels.active.includes(:account).ordered
  end

  def assign_document_relationships(document, template:)
    if @vessel
      document.account = @vessel.account
      return true
    end

    return true if document_account_id.blank? && document_asset_id.blank?

    unless can_manage_document_relationships?
      deny_access!
      return false
    end

    if document_asset_id.present?
      document.asset = manageable_vessels.find(document_asset_id)
      if document_account_id.present? && document_account_id.to_i != document.asset.account_id
        document.errors.add(:asset, "must belong to the selected owner")
        render template, status: :unprocessable_entity
        return false
      end

      document.account = document.asset.account
    elsif document_account_id.present?
      document.account = manageable_accounts.find(document_account_id)
      document.asset = nil
    end

    true
  end

  def attach_document_file!(document, upload)
    document.file.attach(upload)
    raise DocumentFileAttachmentError, "file was not attached" unless document.file.attached?
  rescue DocumentFileAttachmentError
    raise
  rescue StandardError => error
    Rails.logger.error("Document file attachment raised #{error.class}: #{error.message}")
    raise DocumentFileAttachmentError, "could not be attached"
  end

  def render_document_form_with_file_error(document, message, template)
    document.valid?
    document.errors.add(:file, message)
    render template, status: :unprocessable_entity
  end

  def document_account_id
    document_relationship_params[:account_id]
  end

  def document_asset_id
    document_relationship_params[:asset_id]
  end

  def can_manage_document_relationships?
    can_manage_records?
  end

  def require_document_write_access!
    return require_write_access!(@vessel.account) if @vessel

    require_write_access!
  end

  def require_existing_document_write_access!
    require_write_access!(@document.account)
  end

  def after_create_path
    if @document.asset&.asset_type == "vessel"
      vessel_path(@document.asset, anchor: "documents")
    else
      documents_path
    end
  end

  def fallback_location(vessel)
    if vessel
      vessel_path(vessel, anchor: "documents")
    else
      documents_path
    end
  end
end
