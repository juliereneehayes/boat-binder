class AssetBatteriesController < ApplicationController
  before_action :require_internal!, only: :destroy
  before_action :set_vessel
  before_action :require_vessel_write_access!, only: %i[new create edit update]
  before_action :set_battery, only: %i[edit update destroy]

  def new
    @battery = @vessel.asset_batteries.new(active: true)
  end

  def create
    @battery = @vessel.asset_batteries.new(battery_params)

    if @battery.save
      if service_visit_battery_management?
        render :create, formats: :turbo_stream
      else
        redirect_to vessel_path(@vessel, anchor: "batteries"), notice: "Battery added."
      end
    else
      render_battery_form(:new)
    end
  end

  def edit
  end

  def update
    if @battery.update(battery_params)
      if service_visit_battery_management?
        render :update, formats: :turbo_stream
      else
        redirect_to vessel_path(@vessel, anchor: "batteries"), notice: "Battery updated."
      end
    else
      render_battery_form(:edit)
    end
  end

  def destroy
    @battery.destroy!
    redirect_to vessel_path(@vessel, anchor: "batteries"), notice: "Battery removed."
  end

  private

  def set_vessel
    @vessel = scoped_vessels.find_by!(slug: params[:vessel_id])
  end

  def set_battery
    @battery = @vessel.asset_batteries.find(params[:id])
  end

  def require_vessel_write_access!
    require_write_access!(@vessel.account)
  end

  def battery_params
    params.require(:asset_battery).permit(:name, :location, :battery_type, :notes, :active)
  end

  def service_visit_battery_management?
    params[:from_service_visit] == "1" && request.format.turbo_stream?
  end

  def render_battery_form(template)
    options = { status: :unprocessable_entity }
    options[:formats] = :html if params[:from_service_visit] == "1"
    render template, **options
  end
end
