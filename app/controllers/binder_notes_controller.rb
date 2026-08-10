class BinderNotesController < ApplicationController
  before_action :require_write_access!
  before_action :set_vessel
  before_action :require_vessel_write_access!
  before_action :set_binder_note, only: %i[edit update destroy]

  def create
    @binder_note = @vessel.binder_notes.new(binder_note_params)
    @binder_note.account = @vessel.account

    if @binder_note.save
      redirect_to vessel_path(@vessel, anchor: "notes"), notice: "Note added."
    else
      redirect_to vessel_path(@vessel, anchor: "notes"), alert: @binder_note.errors.full_messages.to_sentence
    end
  end

  def edit
  end

  def update
    if @binder_note.update(binder_note_params)
      redirect_to vessel_path(@vessel, anchor: "notes"), notice: "Note updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @binder_note.destroy!
    redirect_to vessel_path(@vessel, anchor: "notes"), notice: "Note removed."
  end

  private

  def set_vessel
    @vessel = scoped_vessels.find_by!(slug: params[:vessel_id])
  end

  def set_binder_note
    @binder_note = @vessel.binder_notes.find(params[:id])
  end

  def require_vessel_write_access!
    require_write_access!(@vessel.account)
  end

  def binder_note_params
    params.require(:binder_note).permit(:title, :body, :note_type, :due_date)
  end
end
