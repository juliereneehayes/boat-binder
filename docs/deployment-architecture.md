# Deployment Architecture Review

This review documents the current Boat Binder deployment shape and the work required to add a dedicated staging environment. It is intentionally discovery-only: it does not implement staging, change deployment behavior, or introduce new infrastructure.

## Current Architecture

Boat Binder is a Rails 8.1 application deployed with Heroku-oriented process files. The production process model in `Procfile` defines:

- `web: bundle exec puma -C config/puma.rb`
- `release: bin/rails db:migrate`

Local development uses `Procfile.dev` with Rails and Tailwind watchers through `bin/dev`.

Production Rails configuration lives in `config/environments/production.rb` and currently assumes a Heroku-style runtime:

- `RAILS_ENV=production`
- `SECRET_KEY_BASE` supplied as an environment-specific Heroku config var
- SSL forced with `config.assume_ssl = true` and `config.force_ssl = true`
- logs emitted to STDOUT
- assets served with long-lived cache headers
- Active Storage service set to `:amazon`
- Action Mailer configured for SMTP delivery
- Solid Cache, Solid Queue, and Solid Cable enabled through database-backed adapters

PostgreSQL is the only configured database adapter. Production has one primary database configuration
backed by `DATABASE_URL`; application data, Solid Cache, Solid Queue, and Solid Cable all use that
connection. Their tables are maintained by ordinary migrations in `db/migrate`, so the Heroku release
command `bin/rails db:migrate` initializes a fresh database and upgrades an existing database through
one tracked path. The former component-specific schema files and logical aliases were removed because
Rails tracks initialization at the physical database level, making separate schema dumps unreliable
when every alias points to the same PostgreSQL database.

Active Storage uses local disk in development, test disk storage in test, and S3 in production. The S3 service reads:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_BUCKET`

Transactional email is production-only SMTP through Mailgun-compatible settings:

- `SMTP_ADDRESS`
- `SMTP_PORT`
- `SMTP_DOMAIN`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `MAIL_FROM`
- `APP_HOST`

Production mailer URL helpers use `APP_HOST` with `https`. Development uses `localhost:3000`; test uses `example.com`.

Stripe is configured centrally in `config/initializers/stripe.rb` and `Billing::StripeConfiguration`. Production stores Stripe values in Heroku config vars. The initializer reads environment variables first and retains its existing Rails-credentials fallback:

- `STRIPE_SECRET_KEY`
- `STRIPE_PUBLISHABLE_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_LIVEMODE`
- `STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID`
- `STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID`

The Stripe webhook endpoint is `POST /webhooks/stripe`. It is unauthenticated, skips CSRF only for
that webhook action, verifies the raw request body using Stripe's official signature verification,
and records minimized event metadata in `billing_webhook_events`. Checkout and subscription lifecycle
events reconcile verified Stripe state into the local `Subscription`; unknown and intentionally
deferred events are recorded as ignored. `STRIPE_LIVEMODE` prevents test/live-mode crossover. Local
`Subscription` records remain the source of truth for access; normal application requests do not call
Stripe.

Rails signing uses `SECRET_KEY_BASE` from the production Heroku environment. Production intentionally
does not set `RAILS_MASTER_KEY`, and the repository no longer carries `config/credentials.yml.enc` as
an alternate source. Retired signing and master keys must not be restored as fallbacks.

GitHub Actions CI runs on pull requests and pushes to `main`. It includes separate jobs for Ruby security scanning, importmap audit, RuboCop, Rails tests, and system tests. CI uses PostgreSQL service containers and does not deploy the app.

Documentation currently includes:

- `README.md` for project overview, setup, and verification commands
- `docs/configuration.md` for environment variables
- `docs/email.md` for Mailgun SMTP setup
- `docs/stripe.md` for Stripe webhook setup

The Build Week demo setup is implemented by `BuildWeek::DemoAccountSetup` and `db/seeds/build_week_demo.rb`. It refreshes a fictional owner account with demo vessels, documents, reminders, notes, and service visits. Production requires `BUILD_WEEK_DEMO_PASSWORD`; development and test have a fallback. The regular `db/seeds.rb` is a broader local/demo seed that clears and recreates application data and should not be treated as a production or staging refresh workflow.

## Current Strengths

- Production runtime configuration is environment-variable driven and does not hardcode credentials.
- Production signing has one explicit source of truth in the `SECRET_KEY_BASE` Heroku config var.
- Email, Stripe, S3, demo credentials, and app host values are already externalized.
- Stripe webhook processing has a clear boundary, signature verification, idempotent receipt storage, and privacy-conscious logging/filtering.
- Rails uses account-local timezone helpers for user-facing dates.
- CI is reasonably complete for a small Rails SaaS: tests, system tests, linting, Brakeman, Bundler Audit, and importmap audit.
- The Heroku release phase runs migrations automatically.
- Fresh and existing databases use the same standard migration path for application and Solid tables.
- The demo account setup is repeatable and scoped to a marked fictional account.

## Current Limitations

- There is no dedicated staging Rails environment file or Heroku staging app configuration in the repository.
- There is no documented deployment workflow from PR to staging to production.
- CI validates code but does not deploy, promote, or run post-deploy smoke checks.
- Production host authorization is still commented out. That may be acceptable behind Heroku routing, but staging should force an explicit decision for allowed hosts.
- Production email configuration uses `ENV.fetch`, so a staging app using the production environment will fail to boot unless all SMTP and `APP_HOST` variables are present.
- Production Active Storage uses one generic `:amazon` service. Staging needs a distinct bucket or prefix to avoid mixing user uploads with production files.
- The Stripe documentation currently names the production webhook URL directly. Staging will need its own endpoint, webhook signing secret, and test-mode Price IDs once Checkout is introduced.
- The repository documents Stripe plan Price ID environment variables, but this checkout does not yet contain an application plan catalog implementation. Staging work should reconcile the docs with the eventual billing-plan code before Checkout.
- Solid Queue can run inside Puma only when `SOLID_QUEUE_IN_PUMA` is set; otherwise production needs a worker process such as `bin/jobs`. The current `Procfile` only declares `web` and `release`.
- `db/seeds.rb` is destructive and should remain a local/demo seed only. Staging demo data should use a scoped script or task.

## Production Assumptions Discovered

The following values or behaviors will need environment-specific decisions before staging exists:

- `APP_HOST` controls email and service-visit report links.
- `SECRET_KEY_BASE` is required in production and must be unique to that environment.
- `docs/email.md` examples use `app.boat-binder.com`.
- `docs/stripe.md` documents `https://app.boat-binder.com/webhooks/stripe` as the production webhook endpoint.
- `README.md` lists `https://boat-binder.com` as the live demo.
- Production mail delivery requires Mailgun SMTP variables.
- Production uploads require S3 variables and a bucket.
- Stripe webhook verification requires `STRIPE_WEBHOOK_SECRET`.
- Stripe API key configuration is optional at boot but required for future Stripe-dependent operations.
- `BUILD_WEEK_DEMO_PASSWORD` is required in production.
- Host authorization is not explicitly configured in production.
- `config.cache.yml` namespaces cache entries by `Rails.env`; staging using `RAILS_ENV=production` would share the namespace name `production` unless isolated by database or future configuration.

## Recommended Architecture

Use three explicitly separated operational environments:

```text
Development
  -> Staging
  -> Production
```

### Development

- Local Rails with `RAILS_ENV=development`
- Local PostgreSQL databases
- Local disk Active Storage
- Test or sandbox Mailgun/SMTP only when intentionally testing email
- Stripe CLI forwarding to `localhost:3000/webhooks/stripe`
- Test-mode Stripe keys only

### Staging

Create a separate Heroku app, for example `boat-binder-staging`, running the same Rails production environment:

- `RAILS_ENV=production`
- separate `DATABASE_URL`
- separate S3 bucket, such as `boat-binder-staging`
- separate Mailgun domain or sandbox-compatible SMTP credentials
- staging `APP_HOST`, such as `staging.boat-binder.com` or the Heroku app hostname
- separate staging `SECRET_KEY_BASE` that is never shared with production
- separate Stripe test-mode webhook endpoint and signing secret
- Stripe test-mode Price IDs
- `STRIPE_LIVEMODE=false`
- separate `BUILD_WEEK_DEMO_EMAIL` and `BUILD_WEEK_DEMO_PASSWORD`

Running staging with `RAILS_ENV=production` keeps Rails behavior close to production. A separate `staging.rb` environment could be added later if the app needs visible environment banners, different caching, or more permissive diagnostics, but it also increases configuration drift. For Phase 1 staging, a distinct Heroku app with production Rails behavior and separate config vars is the simpler and safer path.

Recommended staging process types:

- keep `web` and `release`
- decide whether to set `SOLID_QUEUE_IN_PUMA=true` for small MVP staging deployments
- or add a dedicated worker process for `bin/jobs` before relying on queued jobs

### Production

Keep the current Heroku production app as the live environment:

- production PostgreSQL
- production-only `SECRET_KEY_BASE` stored as a Heroku config var
- production S3 bucket
- production Mailgun SMTP credentials
- production `APP_HOST`
- production Stripe live-mode keys and webhook signing secret when billing goes live
- production Stripe live-mode Price IDs and `STRIPE_LIVEMODE=true`
- no demo-data refresh unless intentionally run by an operator

## Recommended Deployment Flow

1. Open PR from feature branch.
2. Require GitHub Actions CI to pass.
3. Merge to `main`.
4. Deploy `main` to staging automatically or manually.
5. Run smoke checks on staging:
   - login
   - dashboard load
   - create/edit a vessel record
   - upload a safe test file/photo
   - request a password reset or invitation in staging email mode
   - send a Stripe CLI/Dashboard test webhook to staging
6. Promote the same reviewed commit to production.
7. Confirm release-phase migrations and production health.

Heroku Pipelines are a good fit if the team wants explicit promotion from staging to production. GitHub Actions deployment can be added later if the team wants deployment events, environment approvals, or post-deploy smoke tests in CI.

## Environment Separation Recommendations

- Use separate Heroku apps for staging and production.
- Use separate `SECRET_KEY_BASE` values. Staging and production must never share Rails signing secrets.
- Use separate PostgreSQL databases.
- Use separate S3 buckets. Do not share production uploads with staging.
- Use separate Mailgun sending domains or clearly labeled staging sender addresses.
- Use Stripe test mode for staging. Do not point staging at live Stripe webhooks or live Price IDs.
- Use separate webhook endpoints and secrets:
  - production: `https://app.boat-binder.com/webhooks/stripe`
  - staging: `https://staging.boat-binder.com/webhooks/stripe` or the chosen staging host
- Use separate `APP_HOST` values so all email links route to the correct environment.
- Use separate demo credentials for staging and production demos.
- Document which environment may contain fictional/demo data and which must not.

## Documentation Updates Needed Once Staging Exists

- Update `README.md` with the staging URL and the high-level deployment flow.
- Expand `docs/configuration.md` into per-environment config var tables.
- Update `docs/email.md` with staging SMTP guidance and sender/domain expectations.
- Update `docs/stripe.md` with staging webhook endpoint setup, test-mode secret handling, and event verification steps.
- Add a deployment runbook that covers staging deploy, smoke tests, production promotion, rollback, and release-phase migration checks.
- Document how to seed or refresh staging demo data without using destructive global seeds.

## Risks And Open Questions

- Confirm the canonical production host. The repository references both `boat-binder.com` and `app.boat-binder.com` in docs/examples.
- Confirm whether production currently uses a Solid Queue worker dyno or `SOLID_QUEUE_IN_PUMA`.
- Confirm whether production uses a dedicated S3 bucket and whether staging should use a separate AWS account, IAM user, bucket, or prefix.
- Confirm whether Mailgun staging should send real email, use a sandbox, or redirect to internal test recipients.
- Confirm whether Heroku deploys are manual, GitHub-connected, or pipeline-based today.
- Decide whether staging should run `RAILS_ENV=production` or a dedicated Rails `staging` environment. The recommendation is `RAILS_ENV=production` for parity unless a concrete staging-only need appears.
- Decide whether host authorization should be explicitly configured once staging and production domains are finalized.
- Reconcile Stripe plan Price ID documentation with the application plan catalog when the plan catalog is present in the deployed branch.

## Follow-Up Work

Recommended implementation order:

1. Create the Heroku staging app and attach a separate PostgreSQL database.
2. Configure a staging-only `SECRET_KEY_BASE`, plus staging `APP_HOST`, SMTP, S3, Stripe test-mode, and demo credentials.
3. Create a staging S3 bucket and least-privilege IAM credentials.
4. Configure a staging Stripe webhook endpoint and store its signing secret.
5. Decide the Solid Queue runtime strategy: `SOLID_QUEUE_IN_PUMA` for MVP staging or a dedicated worker dyno.
6. Add a deployment runbook with staging smoke tests and production promotion steps.
7. Add explicit host authorization for finalized production and staging domains if appropriate.
8. Add a safe staging demo-data refresh command or task that uses the scoped Build Week demo setup.
9. Add optional GitHub Actions deployment automation or Heroku Pipeline promotion after manual deployment is stable.
10. Add environment-specific observability checks for email delivery, Stripe webhook receipt, background jobs, and Active Storage uploads.
