namespace :demo do
  desc "Reset the explicitly configured fictional Build Week demo account"
  task reset: :environment do
    BuildWeek::DemoAccountSetup.call
  end
end
