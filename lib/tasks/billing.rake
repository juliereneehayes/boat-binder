namespace :billing do
  desc "Fail when a Self Managed Account exceeds its active Owner user limit"
  task audit_owner_user_limits: :environment do
    violations = Billing::OwnerUserLimit.violations

    if violations.empty?
      puts "Owner user limit audit passed."
      next
    end

    violations.each do |violation|
      puts "account_id=#{violation.account_id} active_owner_users=#{violation.active_owner_count} limit=#{violation.limit}"
    end

    abort "Owner user limit audit failed for #{violations.length} Account(s)."
  end
end
