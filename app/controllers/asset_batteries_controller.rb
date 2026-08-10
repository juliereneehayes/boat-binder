class AssetBatteriesController < ApplicationController
  before_action :require_internal!
  before_action :set_vessel
  before_action :set_battery, only: %i[edit update destroy]

  def new
    @battery = @vessel.asset_batteries.new(active: true)
  end

  def create
    @battery = @vessel.asset_batteries.new(battery_params)

    if @battery.save
      redirect_to vessel_path(@vessel, anchor: "batteries"), notice: "Battery added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @battery.update(battery_params)
      redirect_to vessel_path(@vessel, anchor: "batteries"), notice: "Battery updated."
    else
      render :edit, status: :unprocessable_entity
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

  def battery_params
    params.require(:asset_battery).permit(:name, :location, :battery_type, :notes, :active)
  end
end
