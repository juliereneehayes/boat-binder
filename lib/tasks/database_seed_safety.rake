namespace :db do
  namespace :seed do
    task production_guard: :environment do
      DatabaseSeedSafety.ensure_allowed!
    end
  end
end

Rake::Task["db:seed"].prerequisites.unshift("db:seed:production_guard")
Rake::Task["db:seed:replant"].prerequisites.unshift("db:seed:production_guard")
