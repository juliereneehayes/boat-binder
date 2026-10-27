module ApplicationHelper
  include AccountTimeZoneContext

  def short_date(value, account: nil)
    account_local_time(value, account)&.strftime("%b %-d, %Y") || "Not recorded"
  end

  def long_date(value, account: nil)
    account_local_time(value, account)&.to_fs(:long) || "Not recorded"
  end

  def short_month(value, account: nil)
    account_local_time(value, account)&.strftime("%b") || ""
  end

  def local_datetime(value, account: nil)
    account_local_time(value, account)&.strftime("%b %-d, %Y at %-l:%M %p %Z") || "Not recorded"
  end

  def account_time_zone_options
    ActiveSupport::TimeZone.all.map do |zone|
      [ zone.to_s, zone.tzinfo.name ]
    end
  end

  def field_error_messages(record)
    return if record.errors.empty?

    tag.div class: "rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-700" do
      safe_join(record.errors.full_messages.map { |message| tag.p(message) })
    end
  end

  def status_chip(text, tone: :neutral)
    colors = {
      neutral: "bg-[#F7F5F2] text-[#0B1F35] ring-1 ring-[#E7DED2]",
      urgent: "bg-red-50 text-red-700 ring-1 ring-red-100",
      success: "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-100",
      warning: "bg-amber-50 text-amber-800 ring-1 ring-amber-100",
      info: "bg-[#E8F3F5] text-[#1E5A7A] ring-1 ring-[#C9DEE2]"
    }

    tag.span text, class: "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-bold #{colors.fetch(tone)}"
  end

  def user_display_name(user)
    user.name.presence || user.email_address
  end

  def user_first_name(user)
    user.name.to_s.split.first.presence || user.email_address.to_s.split("@").first.presence || "there"
  end

  def role_label(user)
    user.role.to_s.humanize
  end

  def dashboard_title
    return "Dashboard" unless Current.user

    "#{role_label(Current.user)} Dashboard"
  end

  def app_card_class(extra = "")
    "rounded-md border border-[#E7DED2] bg-white shadow-sm shadow-[#0B1F35]/5 #{extra}".squish
  end

  def primary_button_class(extra = "")
    "inline-flex min-h-11 items-center justify-center rounded-md bg-[#1E5A7A] px-4 py-2 text-sm font-black text-white shadow-sm transition hover:bg-[#174760] #{extra}".squish
  end

  def secondary_button_class(extra = "")
    "inline-flex min-h-11 items-center justify-center rounded-md border border-[#D7E4E7] bg-white px-4 py-2 text-sm font-black text-[#0B1F35] transition hover:border-[#7DAAB3] hover:bg-[#F7F5F2] #{extra}".squish
  end

  def subtle_link_class(extra = "")
    "rounded-md px-3 py-2 text-sm font-black text-[#1E5A7A] transition hover:bg-[#E8F3F5] #{extra}".squish
  end

  def service_visit_checked_count(visit)
    visit.service_visit_inspection_checks.count(&:checked?)
  end

  def service_visit_total_check_count(visit)
    visit.service_visit_inspection_checks.size
  end

  def service_visit_battery_check_count(visit)
    visit.service_visit_battery_checks.count(&:checked?)
  end

  def service_visit_engine_hour_summary(visit)
    readings = visit.ordered_engine_readings.select { |reading| reading.hours.present? }

    if readings.any?
      readings.map do |reading|
        "#{reading.display_name}: #{number_with_precision(reading.hours, precision: 1, strip_insignificant_zeros: true)}"
      end.to_sentence
    elsif visit.engine_hours.present?
      "#{number_with_precision(visit.engine_hours, precision: 1, strip_insignificant_zeros: true)} hours"
    else
      "Not recorded"
    end
  end

  def service_visit_email_engine_hour_summary(visit)
    recorded_reading_count = if visit.service_visit_engine_readings.loaded?
      visit.service_visit_engine_readings.count { |reading| reading.hours.present? }
    else
      visit.service_visit_engine_readings.where.not(hours: nil).count
    end

    if recorded_reading_count.positive?
      engine_label = "engine".pluralize(recorded_reading_count)
      "#{recorded_reading_count} #{engine_label} recorded"
    elsif visit.engine_hours.present?
      "#{number_with_precision(visit.engine_hours, precision: 1, strip_insignificant_zeros: true)} hours"
    else
      "Not recorded"
    end
  end

  def service_visit_photo_count(visit)
    visit.photos.attachments.size
  end

  def service_visit_follow_up_items(visit, limit: 3)
    visit.follow_up_notes.to_s.lines
      .map { |line| line.strip.sub(/\A[-*]\s*/, "") }
      .select(&:present?)
      .first(limit)
  end

  def vessel_primary_photo(vessel, image_class:, placeholder_class:)
    if vessel.primary_photo.attached? && attachment_available?(vessel.primary_photo)
      image_tag vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id),
        alt: "#{vessel.name} primary photo", class: image_class
    else
      tag.div class: placeholder_class, role: "img", aria: { label: "Primary photo placeholder for #{vessel.name}" } do
        content = [
          tag.div(vessel.name.to_s.first.to_s.upcase, class: "text-4xl font-black text-white/90"),
          tag.div(vessel.location_label, class: "mt-2 text-xs font-black uppercase tracking-normal text-[#B9D5DA]")
        ]
        if vessel.primary_photo.attached?
          content << tag.p(attachment_scan_message(vessel.primary_photo), class: "mt-3 max-w-lg text-xs font-semibold text-white")
        end
        safe_join(content)
      end
    end
  end

  def vessel_primary_photo_upload_surface(vessel, surface_class:, image_class:, placeholder_class:)
    tag.div(
      vessel_primary_photo(vessel, image_class:, placeholder_class:),
      id: "vessel-primary-photo-upload-preview",
      class: surface_class,
      data: {
        upload_preview_target: "surface"
      }
    )
  end

  def vessel_primary_photo_scan_state(vessel)
    return "empty" unless vessel.primary_photo.attached?

    attachment_scan_status(vessel.primary_photo) || "failed"
  end

  def attachment_available?(attachment)
    attachment_scan_for(attachment)&.available? || false
  end

  def attachment_scan_status(attachment)
    attachment_scan_for(attachment)&.status
  end

  def attachment_scan_message(attachment)
    case attachment_scan_status(attachment)
    when "pending"
      attachment_pending_message
    when "rejected"
      "This upload was rejected by security scanning. Retry the upload. If you believe this is an error, contact support@boat-binder.com."
    else
      "This upload is temporarily unavailable. Retry the upload. If the problem continues, contact support@boat-binder.com."
    end
  end

  def attachment_status_label(attachment, available_label: "File attached")
    case attachment_scan_status(attachment)
    when "clean", "trusted_existing"
      available_label
    when "pending"
      attachment_pending_message
    when "rejected"
      "Rejected"
    else
      "Unavailable"
    end
  end

  def attachment_status_tone(attachment)
    case attachment_scan_status(attachment)
    when "clean", "trusted_existing"
      :success
    when "pending"
      :neutral
    else
      :warning
    end
  end

  def attachment_pending_message
    "Processing upload…"
  end

  def attachment_status_check_link(path = request.fullpath, accessible_name: nil)
    options = {
      class: "inline-flex min-h-10 items-center rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-bold text-slate-700 transition hover:bg-slate-50",
      data: { turbo_action: "replace" }
    }
    options[:aria] = { label: accessible_name } if accessible_name

    link_to "Check status", path, **options
  end

  def attachment_group_scan_state(attachments)
    attachments = attachments.to_a
    return "empty" if attachments.empty?

    statuses = attachments.map { |attachment| attachment_scan_status(attachment) }
    return "pending" if statuses.include?("pending")
    return "rejected" if statuses.include?("rejected")
    return "failed" if statuses.any? { |status| status.blank? || status == "failed" }

    "clean"
  end

  private

  def attachment_scan_for(attachment)
    attachment = attachment.attachment if attachment.respond_to?(:attachment)
    blob = attachment&.blob
    return unless blob

    @attachment_scan_cache ||= {}
    scan = @attachment_scan_cache.fetch(blob.id) do
      @attachment_scan_cache[blob.id] = AttachmentScan.find_by(active_storage_blob_id: blob.id)
    end
    scan
  end

  public

  def app_nav_items
    items = [ [ "Dashboard", root_path, "D" ], [ "Settings", settings_path, "S" ] ]
    return items if owner_lifecycle_restricted?

    items << [ "Vessels", vessels_path, "V" ]
    items << [ "Owners", owners_path, "O" ] if internal_user?
    items << [ "Documents", documents_path, "F" ]
    items << [ "Service Visits", service_visits_path, "S" ]
    items << [ "Users", admin_users_path, "U" ] if admin_user?
    items << [ "Export Requests", admin_account_export_requests_path, "E" ] if admin_user?
    items
  end
end
