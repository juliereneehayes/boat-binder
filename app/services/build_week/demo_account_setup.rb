module BuildWeek
  class DemoAccountSetup
    class ConflictError < StandardError; end
    class MissingCredentialError < StandardError; end

    DEMO_MARKER = "[Build Week demo account]".freeze
    ACCOUNT_NAME = "Alex Johnson"
    DEFAULT_EMAIL = "demo@boat-binder.com"
    DEFAULT_PASSWORD = "boat-binder-build-week-demo"
    ACCOUNT_TIME_ZONE = "America/Los_Angeles"

    Result = Struct.new(:account, :user, :vessels, keyword_init: true)

    def self.call(output: $stdout)
      new(output: output).call
    end

    def initialize(output:)
      @output = output
    end

    def call
      result = nil

      ActiveRecord::Base.transaction do
        account = find_or_create_account
        user = find_or_create_user(account)

        ensure_membership!(account, user)
        ensure_subscription!(account)
        refresh_demo_content!(account, user)

        result = Result.new(account: account, user: user, vessels: account.assets.vessels.ordered.to_a)
      end

      print_summary(result)
      result
    end

    private

    attr_reader :output

    def demo_email
      ENV.fetch("BUILD_WEEK_DEMO_EMAIL", DEFAULT_EMAIL).to_s.strip.downcase
    end

    def demo_password
      password = ENV["BUILD_WEEK_DEMO_PASSWORD"].presence
      return password if password.present?
      return DEFAULT_PASSWORD unless Rails.env.production?

      raise MissingCredentialError, "BUILD_WEEK_DEMO_PASSWORD must be set in production"
    end

    def find_or_create_account
      marked_accounts = marked_demo_accounts

      case marked_accounts.count
      when 1
        update_account!(marked_accounts.first)
      when 0
        raise ConflictError, "Account #{ACCOUNT_NAME.inspect} exists but is not marked as the Build Week demo account" if accounts_matching_name.exists?

        create_account
      else
        raise ConflictError, "Multiple Build Week demo accounts exist for #{ACCOUNT_NAME.inspect}"
      end
    end

    def create_account
      creator = AccountCreator.call(account_attributes: account_attributes)
      raise ActiveRecord::RecordInvalid, creator.account unless creator.success?

      creator.account
    end

    def update_account!(account)
      account.update!(account_attributes.merge(notes: demo_notes(account.notes)))
      account
    end

    def account_attributes
      {
        name: ACCOUNT_NAME,
        account_type: "client",
        active: true,
        time_zone: ACCOUNT_TIME_ZONE,
        notes: demo_notes
      }
    end

    def demo_notes(existing_notes = nil)
      notes = existing_notes.to_s.strip
      return "#{DEMO_MARKER} Fictional owner dataset for Boat Binder Build Week judging." if notes.blank?
      return notes if notes.include?(DEMO_MARKER)

      "#{DEMO_MARKER} #{notes}"
    end

    def accounts_matching_name
      Account.where(name: ACCOUNT_NAME)
    end

    def marked_demo_accounts
      accounts_matching_name.where("notes LIKE ?", "%#{Account.sanitize_sql_like(DEMO_MARKER)}%")
    end

    def find_or_create_user(account)
      user = User.find_by(email_address: demo_email)
      validate_user_conflict!(user, account) if user

      user ||= User.new(email_address: demo_email)
      user.assign_attributes(
        name: ACCOUNT_NAME,
        role: "owner",
        active: true,
        invitation_sent_at: nil,
        invitation_accepted_at: nil,
        password: demo_password,
        password_confirmation: demo_password
      )
      user.save!
      user
    end

    def validate_user_conflict!(user, account)
      raise ConflictError, "User #{demo_email.inspect} exists but is not an owner user" unless user.owner?

      other_memberships = user.account_memberships.where.not(account_id: account.id)
      return unless other_memberships.exists?

      raise ConflictError, "User #{demo_email.inspect} already belongs to a non-demo account"
    end

    def ensure_membership!(account, user)
      membership = AccountMembership.find_or_initialize_by(account: account, user: user)
      membership.update!(access_level: "editor", active: true)
    end

    def ensure_subscription!(account)
      subscription = account.subscription || account.build_subscription
      subscription.assign_attributes(
        Subscription.default_local_attributes.merge(
          external_customer_id: nil,
          external_subscription_id: nil,
          trial_ends_at: nil,
          current_period_ends_at: nil,
          cancel_at_period_end: false,
          canceled_at: nil,
          last_synced_at: nil
        )
      )
      subscription.save!
    end

    def refresh_demo_content!(account, user)
      remove_demo_content!(account)
      Contact.create!(
        account: account,
        name: ACCOUNT_NAME,
        email: demo_email,
        phone: "555-0137",
        role: "Owner"
      )

      create_vessels(account, user)
    end

    def remove_demo_content!(account)
      account.documents.find_each(&:destroy!)
      account.binder_notes.find_each(&:destroy!)
      account.contacts.find_each(&:destroy!)
      account.assets.find_each(&:destroy!)
    end

    def create_vessels(account, user)
      vessel_definitions.map do |definition|
        vessel = Asset.create!(definition.fetch(:attributes).merge(account: account, asset_type: "vessel", active: true))
        create_engines(vessel, definition.fetch(:engines))
        create_batteries(vessel, definition.fetch(:batteries))
        create_documents(account, vessel, definition.fetch(:documents))
        create_notes(account, vessel, definition.fetch(:notes))
        create_reminders(vessel, definition.fetch(:reminders))
        create_service_visits(vessel, user, definition.fetch(:service_visits))
        vessel
      end
    end

    def create_engines(vessel, engines)
      engines.each_with_index do |name, index|
        AssetEngine.create!(asset: vessel, name: name, position: index + 1, active: true)
      end
    end

    def create_batteries(vessel, batteries)
      batteries.each do |battery|
        AssetBattery.create!(battery.merge(asset: vessel, active: true))
      end
    end

    def create_documents(account, vessel, documents)
      documents.each do |document|
        Document.create!(document.merge(account: account, asset: vessel))
      end
    end

    def create_notes(account, vessel, notes)
      notes.each do |note|
        BinderNote.create!(note.merge(account: account, asset: vessel))
      end
    end

    def create_reminders(vessel, reminders)
      reminders.each do |reminder|
        Reminder.create!(reminder.merge(asset: vessel))
      end
    end

    def create_service_visits(vessel, user, visits)
      visits.each do |visit_definition|
        visit = ServiceVisit.create!(
          visit_definition.fetch(:attributes).merge(asset: vessel, performed_by_user: user)
        )
        create_engine_readings(visit, vessel, visit_definition.fetch(:engine_hours))
        create_inspection_checks(visit, visit_definition.fetch(:inspection_notes))
        create_battery_checks(visit, vessel, visit_definition.fetch(:battery_notes))
      end
    end

    def create_engine_readings(visit, vessel, engine_hours)
      vessel.asset_engines.ordered.each_with_index do |engine, index|
        ServiceVisitEngineReading.create!(
          service_visit: visit,
          asset_engine: engine,
          hours: engine_hours.fetch(index)
        )
      end
    end

    def create_inspection_checks(visit, inspection_notes)
      ServiceVisit::DEFAULT_INSPECTION_LABELS.each_with_index do |label, index|
        note = inspection_notes[label]
        ServiceVisitInspectionCheck.create!(
          service_visit: visit,
          label: label,
          checked: note != false,
          notes: note == false ? "Needs attention." : note,
          position: index + 1
        )
      end
    end

    def create_battery_checks(visit, vessel, battery_notes)
      vessel.asset_batteries.ordered.each_with_index do |battery, index|
        ServiceVisitBatteryCheck.create!(
          service_visit: visit,
          asset_battery: battery,
          checked: true,
          voltage: 12.58 + (index * 0.07),
          notes: battery_notes.fetch(battery.name, "Charging normally.")
        )
      end
    end

    def vessel_definitions
      today = Time.zone.today

      [
        {
          attributes: {
            name: "Sea Breeze",
            make: "Jeanneau",
            model: "NC 695",
            year: 2023,
            length: 24,
            registration_number: "BW-SB-2023",
            marina: "Shilshole Bay Marina",
            slip: "G-18",
            notes: "Fictional Build Week vessel. Owner prefers concise updates before weekend use."
          },
          engines: [ "Main Outboard" ],
          batteries: [
            { name: "House Battery", location: "Aft locker", battery_type: "AGM", notes: "Supports cabin electronics." },
            { name: "Start Battery", location: "Transom compartment", battery_type: "AGM", notes: "Outboard start battery." }
          ],
          documents: [
            { title: "Sea Breeze registration", document_type: "registration", notes: "Fictional registration metadata for demo review." },
            { title: "Sea Breeze insurance binder", document_type: "insurance", notes: "Fictional policy summary; no private documents attached." },
            { title: "Sea Breeze spring maintenance record", document_type: "maintenance_record", notes: "Impeller inspected and safety kit reviewed." }
          ],
          notes: [
            { title: "Owner preference", body: "Send a brief report after dockside checks and flag anything affecting weekend use.", note_type: "owner_preference", due_date: nil },
            { title: "Canvas snap watch", body: "Forward starboard canvas snap is tight and should be handled carefully.", note_type: "maintenance", due_date: today + 10.days }
          ],
          reminders: [
            { title: "Renew vessel registration", due_date: today + 18.days, reminder_type: "registration", status: "pending" },
            { title: "Replace expired flares", due_date: today - 3.days, reminder_type: "inspection", status: "pending" },
            { title: "Spring engine service completed", due_date: today - 20.days, reminder_type: "maintenance", status: "completed", completed_at: Time.current - 19.days }
          ],
          service_visits: [
            {
              attributes: {
                visit_date: today - 2.days,
                engine_hours: 86.4,
                location: "Shilshole Bay Marina, Slip G-18",
                summary: "Dockside check completed before a planned family outing.",
                condition_notes: "Bilge dry, cabin secure, shore power connected, and dock lines holding well.",
                follow_up_needed: true,
                follow_up_notes: "Replace expired flares and confirm the new kit is onboard."
              },
              engine_hours: [ 86.4 ],
              inspection_notes: { "Safety equipment" => false, "Dock lines" => "Lines secure with light chafe at bow." },
              battery_notes: { "House Battery" => "12.58V at rest after charging.", "Start Battery" => "12.65V and terminals clean." }
            },
            {
              attributes: {
                visit_date: today - 21.days,
                engine_hours: 82.1,
                location: "Shilshole Bay Marina, Slip G-18",
                summary: "Routine spring check after launch.",
                condition_notes: "Systems powered normally and cockpit was clean.",
                follow_up_needed: false,
                follow_up_notes: "No follow-up items noted."
              },
              engine_hours: [ 82.1 ],
              inspection_notes: { "Hull" => "Hull clean at waterline.", "Bilge" => "Dry." },
              battery_notes: { "House Battery" => "Charging normally.", "Start Battery" => "Charging normally." }
            }
          ]
        },
        {
          attributes: {
            name: "Reel Escape",
            make: "Boston Whaler",
            model: "170 Montauk",
            year: 2018,
            length: 17,
            registration_number: "BW-RE-2018",
            marina: "Elliott Bay Marina",
            slip: "Dry Rack 12",
            notes: "Fictional Build Week fishing skiff used for simple owner workflows."
          },
          engines: [ "Main Outboard" ],
          batteries: [
            { name: "Start Battery", location: "Console", battery_type: "AGM", notes: "Console-mounted start battery." }
          ],
          documents: [
            { title: "Reel Escape registration", document_type: "registration", notes: "Fictional registration metadata for demo review." },
            { title: "Reel Escape fuel receipts", document_type: "receipt", notes: "Fictional operating-cost record for demo review." }
          ],
          notes: [
            { title: "Fishing gear storage", body: "Owner keeps spare life jackets in the forward locker.", note_type: "owner_preference", due_date: nil },
            { title: "Trailer strap", body: "Inspect transom straps before the next road move.", note_type: "maintenance", due_date: today + 7.days }
          ],
          reminders: [
            { title: "Annual safety inspection", due_date: today + 30.days, reminder_type: "inspection", status: "pending" },
            { title: "Washdown pump follow-up", due_date: today - 1.day, reminder_type: "maintenance", status: "pending" }
          ],
          service_visits: [
            {
              attributes: {
                visit_date: today - 5.days,
                engine_hours: 142.8,
                location: "Elliott Bay Marina, Dry Rack 12",
                summary: "Pre-weekend check with fuel, battery, and safety gear review.",
                condition_notes: "Console dry, bilge clear, and hull exterior clean.",
                follow_up_needed: false,
                follow_up_notes: "No follow-up items noted."
              },
              engine_hours: [ 142.8 ],
              inspection_notes: { "Hull" => "No new marks observed.", "Safety equipment" => "Life jackets present." },
              battery_notes: { "Start Battery" => "12.7V and clean terminals." }
            },
            {
              attributes: {
                visit_date: today - 32.days,
                engine_hours: 137.5,
                location: "Elliott Bay Marina, Dry Rack 12",
                summary: "Monthly check after storage.",
                condition_notes: "Boat was clean and covers were secure.",
                follow_up_needed: true,
                follow_up_notes: "Washdown pump switch should be tested again after next launch."
              },
              engine_hours: [ 137.5 ],
              inspection_notes: { "Systems" => false, "Interior" => "Console clean and dry." },
              battery_notes: { "Start Battery" => "Charging normally." }
            }
          ]
        }
      ]
    end

    def print_summary(result)
      output.puts "Build Week demo account refreshed."
      output.puts "Account: #{result.account.name}"
      output.puts "Login email: #{result.user.email_address}"
      output.puts "Vessels: #{result.vessels.map(&:name).join(', ')}"
      output.puts "Documents: #{result.account.documents.count}"
      output.puts "Service visits: #{result.account.assets.joins(:service_visits).count}"
      output.puts "Reminders: #{result.account.assets.joins(:reminders).count}"
      output.puts "Password: set from BUILD_WEEK_DEMO_PASSWORD; production requires this variable."
    end
  end
end
