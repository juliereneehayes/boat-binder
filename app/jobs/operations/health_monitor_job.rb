require "digest"

module Operations
  class HealthMonitorJob < ApplicationJob
    queue_as :background

    ALERT_REMINDER_INTERVAL = 24.hours
    STALE_SCAN_RECOVERY_GRACE = 10.minutes
    MAX_FAILED_JOB_CLASSES = 25
    CACHE_NAMESPACE = "operations/health-monitor/v2".freeze
    SAFE_CLASS_NAME = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/

    def perform(now: Time.current)
      conditions = health_conditions(now:)
      return if conditions.empty?

      recipient = Rails.configuration.x.operations.alert_recipient
      unless recipient.present?
        Rails.logger.error(
          "Operational health alert result=skipped reason=recipient_not_configured " \
          "categories=#{categories(conditions).join(',')}"
        )
        return
      end

      cache_key = alert_cache_key(conditions)
      return if recently_alerted?(cache_key)

      ActionMailer::Base.logger.silence(Logger::FATAL) do
        OperationalAlertsMailer.health_alert(conditions:, detected_at: now, recipient:).deliver_now
      end
      remember_alert(cache_key)
      Rails.logger.warn(
        "Operational health alert result=delivered categories=#{categories(conditions).join(',')}"
      )
    rescue *ApplicationMailer::DELIVERY_ERRORS => error
      Rails.logger.error(
        "Operational health alert result=delivery_failed exception_class=#{error.class.name}"
      )
    end

    private

    def health_conditions(now:)
      [
        failed_jobs_condition,
        failed_attachment_scans_condition,
        stale_attachment_scans_condition(now:)
      ].compact
    end

    def failed_jobs_condition
      scope = SolidQueue::FailedExecution.joins(:job)
      total_count = scope.count
      return if total_count.zero?

      groups = scope
        .group("solid_queue_jobs.class_name")
        .order(Arel.sql("MAX(solid_queue_failed_executions.created_at) DESC"))
        .limit(MAX_FAILED_JOB_CLASSES)
        .pluck(
          "solid_queue_jobs.class_name",
          Arel.sql("COUNT(*)"),
          Arel.sql("MIN(solid_queue_failed_executions.created_at)"),
          Arel.sql("MAX(solid_queue_failed_executions.created_at)")
        )
        .map do |job_class, count, first_failed_at, most_recent_failed_at|
          {
            job_class: safe_class_name(job_class),
            count:,
            first_failed_at: timestamp(first_failed_at),
            most_recent_failed_at: timestamp(most_recent_failed_at)
          }
        end

      {
        category: "failed_background_jobs",
        total_count:,
        job_classes: failed_job_classes(scope),
        omitted_job_class_count: failed_job_class_count(scope) - groups.size,
        groups:
      }
    end

    def failed_job_classes(scope)
      scope.distinct.pluck("solid_queue_jobs.class_name").map { |name| safe_class_name(name) }.uniq.sort
    end

    def failed_job_class_count(scope)
      scope.distinct.count("solid_queue_jobs.class_name")
    end

    def failed_attachment_scans_condition
      scope = AttachmentScan.where(status: "failed")
      total_count = scope.count
      return if total_count.zero?

      groups = scope
        .group(:status_code)
        .order(Arel.sql("MAX(completed_at) DESC NULLS LAST"))
        .pluck(:status_code, Arel.sql("COUNT(*)"), Arel.sql("MIN(completed_at)"), Arel.sql("MAX(completed_at)"))
        .map do |status_code, count, first_failed_at, most_recent_failed_at|
          {
            status_code: safe_status_code(status_code),
            count:,
            first_failed_at: timestamp(first_failed_at),
            most_recent_failed_at: timestamp(most_recent_failed_at)
          }
        end

      { category: "failed_attachment_scans", total_count:, groups: }
    end

    def stale_attachment_scans_condition(now:)
      cutoff = now - Storage::AttachmentScanJob::POLL_WINDOW - STALE_SCAN_RECOVERY_GRACE
      scope = AttachmentScan.where(status: "pending", created_at: ...cutoff)
      count, oldest_created_at, most_recent_created_at = scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("MIN(created_at)"),
        Arel.sql("MAX(created_at)")
      )
      return if count.zero?

      {
        category: "stale_attachment_scans",
        count:,
        oldest_created_at: timestamp(oldest_created_at),
        most_recent_created_at: timestamp(most_recent_created_at)
      }
    end

    def alert_cache_key(conditions)
      fingerprint = Digest::SHA256.hexdigest(structural_conditions(conditions).to_json)
      "#{CACHE_NAMESPACE}/#{fingerprint}"
    end

    def structural_conditions(conditions)
      conditions.map do |condition|
        case condition[:category]
        when "failed_background_jobs"
          {
            category: condition[:category],
            job_classes: condition[:job_classes]
          }
        when "failed_attachment_scans"
          {
            category: condition[:category],
            status_codes: condition[:groups].pluck(:status_code).uniq.sort
          }
        else
          { category: condition[:category] }
        end
      end.sort_by { |condition| condition[:category] }
    end

    def recently_alerted?(cache_key)
      cache_store.exist?(cache_key)
    rescue StandardError => error
      log_cache_failure("read_failed", error)
      false
    end

    def remember_alert(cache_key)
      cache_store.write(cache_key, true, expires_in: ALERT_REMINDER_INTERVAL)
    rescue StandardError => error
      log_cache_failure("write_failed", error)
    end

    def cache_store
      Rails.cache
    end

    def log_cache_failure(result, error)
      Rails.logger.error(
        "Operational health alert cache result=#{result} exception_class=#{error.class.name}"
      )
    end

    def safe_class_name(value)
      value.to_s.match?(SAFE_CLASS_NAME) ? value : "UnknownJob"
    end

    def safe_status_code(value)
      AttachmentScan::STATUS_CODES.include?(value) ? value : "UNKNOWN"
    end

    def timestamp(value)
      value&.utc&.iso8601
    end

    def categories(conditions)
      conditions.pluck(:category)
    end
  end
end
