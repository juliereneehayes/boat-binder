web: bundle exec puma -C config/puma.rb
worker: bin/jobs --mode async
release: bin/rails db:migrate
