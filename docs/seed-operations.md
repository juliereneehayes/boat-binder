# Seed And Demo Operations

Boat Binder separates ordinary database initialization from the one retained fictional demo reset.
Neither path is a production recovery tool.

## Authoritative Paths

- `bin/rails db:prepare` runs migrations and prepares a development or test database.
- `bin/rails db:seed` creates no users or sample records outside production and aborts immediately
  in production.
- `bin/rails demo:reset` is the only destructive demo population path. It delegates to
  `BuildWeek::DemoAccountSetup` and refreshes only the uniquely marked fictional Account.

The former seed body that deleted all users, Accounts, records, and attachments has been removed.
The former `db/seeds/build_week_demo.rb` runner is superseded by `demo:reset`. Build Week naming and
the decision to retire or repurpose this contest-specific dataset remain with #125.

## Development

Prepare the database normally:

```sh
bin/rails db:prepare
bin/rails db:seed
```

The seed command is safe to repeat and does not create a privileged user. Create normal Owner users
through self-service registration. Admin and Captain identities are not created with known defaults.

To populate the fictional demo Account, provide all values through the shell or an appropriate
local secret manager. Do not put the password in shell history or committed files.

```sh
export BUILD_WEEK_DEMO_EMAIL
export BUILD_WEEK_DEMO_PASSWORD
export BUILD_WEEK_DEMO_ALLOWED_ENVIRONMENTS=development
export BUILD_WEEK_DEMO_CONFIRMATION='RESET BUILD WEEK DEMO'
bin/rails demo:reset
```

The command fails before mutation when credentials, environment eligibility, or confirmation are
missing. It does not print the configured email or password.

## Staging And Demo Environments

Boat Binder does not currently have a dedicated staging Rails environment. The recommended staging
architecture runs with `RAILS_ENV=production`, so both `db:seed` and `demo:reset` are deliberately
prohibited there. Do not relabel a production-mode environment merely to bypass these guards.

If #125 retains a staging demo, it must establish a distinct supported environment and identity,
separate credentials, backups, and an allowlist before using the scoped reset. The Account marker is
only a reset target; it is not an authentication, authorization, or entitlement exception.

## Production

Never run `db:seed`, `db:seed:replant`, or `demo:reset` in production. No force flag or production
bypass exists. Use migrations for schema deployment and narrowly scoped application or console
procedures for confirmed operational remediation. A database backup must be available and verified
before any production data operation:

```sh
heroku pg:backups --app boat-binder
```

The code change itself has no migration and performs no deployed data mutation. Rolling back to a
release containing the former seed body would restore the destructive/default-credential hazard;
use a forward fix instead.

## Known Test-Identity Verification

The historical seed created predictable Admin and Captain test identities. Code completion does not
prove those identities are absent from deployed environments. Run this privacy-minimized inspection
separately against each confirmed staging and production app; it prints record IDs, roles, active
state, and session counts, but not passwords or email addresses:

```sh
heroku run 'bin/rails runner '\''emails = %w[admin@hayesyacht.test captain@hayesyacht.test]; User.where(email_address: emails).order(:id).find_each { |user| puts({ id: user.id, role: user.role, active: user.active?, sessions: user.sessions.count }.to_json) }'\''' --app boat-binder
```

Replace the app name when inspecting a separately confirmed staging app. If no rows are printed, the
known identities are absent. Do not interpret that result as a search for every possible test user.

For each confirmed match, verify the target and backup first, then deactivate it and invalidate its
sessions through the established Rails console without printing or setting a password:

```sh
heroku run bin/rails console --app boat-binder
```

```ruby
user = User.find(CONFIRMED_USER_ID)
raise "Unexpected identity" unless %w[admin@hayesyacht.test captain@hayesyacht.test].include?(user.email_address)

User.transaction do
  user.lock!
  user.update!(active: false)
  user.sessions.delete_all
end
```

Repeat only for an explicitly confirmed target. Do not delete Accounts, customer records, or
attachments. Verify afterward that the user is inactive, has no sessions, and cannot authenticate.
Deployed staging/production verification and remediation remain owner-operated and pending until
their results are recorded without sensitive values.

## Manual Regression Checks

- Development: `db:prepare` and `db:seed` succeed without creating users or printing credentials.
- Scoped demo: allowlisted environment plus exact confirmation succeeds; missing either fails before
  mutation; an unrelated Account and attachment remain unchanged.
- Production safety: rely on automated production-environment coverage. Do not run a destructive
  production command to test the guard.
