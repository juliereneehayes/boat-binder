# Seed Operations

Boat Binder keeps ordinary database initialization separate from operational data changes. The
historical Build Week authenticated demo and its destructive reset path have been retired. There is
no supported command for recreating or refreshing that contest dataset; future demo work belongs to
#103.

## Authoritative Paths

- `bin/rails db:prepare` runs migrations and prepares a development or test database.
- `bin/rails db:seed` creates no users or sample records outside production and aborts immediately
  in production.
- No demo population or reset task is supported.

The former seed body that deleted all users, Accounts, records, and attachments remains removed.
Do not restore `db/seeds/build_week_demo.rb`, `demo:reset`, predictable privileged credentials, or a
replacement destructive task.

## Development

Prepare the database normally:

```sh
bin/rails db:prepare
bin/rails db:seed
```

The seed command is safe to repeat and does not create a privileged user or sample Account. Create
normal Owner users through self-service registration. Admin and Captain identities are not created
with known defaults.

## Staging

Boat Binder has a separate Heroku staging app but no dedicated Rails `staging` environment file. The
staging deployment uses production-equivalent seed protections, so `db:seed` is deliberately
prohibited there. Do not relabel a production-mode environment to bypass the guard, and do not
restore the retired Build Week task as a staging shortcut. Any future public or staging demo must be
designed separately under #103 with its own identity, data lifecycle, and security review.

## Production

Never run `db:seed` or `db:seed:replant` in production. No force flag or production bypass exists.
Use migrations for schema deployment and narrowly scoped application or console procedures for
confirmed operational remediation. A database backup must be available and verified before any
production data operation:

```sh
heroku pg:backups --app boat-binder
```

This retirement has no migration and performs no deployed data mutation. It does not delete Accounts,
Users, customer records, attachments, uploads, subscriptions, or Stripe state.

## Retired Build Week Operational Cleanup

Apply this sequence separately to each confirmed staging and production app. Commands below report
only record IDs, active/session state, or configuration-key presence. They do not print credential
values.

1. Before deployment, confirm the marked historical demo identity is still inactive and has no
   Sessions:

   ```sh
   heroku run 'bin/rails runner '\''marker = "[Build Week demo account]"; Account.where("notes LIKE ?", "%#{Account.sanitize_sql_like(marker)}%").order(:id).find_each { |account| account.users.order(:id).find_each { |user| puts({ account_id: account.id, user_id: user.id, active: user.active?, sessions: user.sessions.count }.to_json) } }'\''' --app APP_NAME
   ```

   No output means the marked identity is absent. Any returned identity must have `active: false`
   and `sessions: 0`. Stop if it does not; do not set a password, reactivate it, or recreate it.

2. Deploy the reviewed code that removes the Build Week setup service and `demo:reset` task.
3. Verify normal login, dashboard access, Account and User access, uploads, and application health.
4. Check only whether each retired key exists in that environment:

   ```sh
   heroku run 'bin/rails runner '\''keys = %w[BUILD_WEEK_DEMO_EMAIL BUILD_WEEK_DEMO_PASSWORD BUILD_WEEK_DEMO_ALLOWED_ENVIRONMENTS BUILD_WEEK_DEMO_CONFIRMATION]; puts keys.to_h { |key| [key, ENV.key?(key)] }.to_json'\''' --app APP_NAME
   ```

5. After the new release is healthy, remove any keys reported as present, then repeat the health and
   login checks:

   ```sh
   heroku config:unset BUILD_WEEK_DEMO_EMAIL BUILD_WEEK_DEMO_PASSWORD BUILD_WEEK_DEMO_ALLOWED_ENVIRONMENTS BUILD_WEEK_DEMO_CONFIRMATION --app APP_NAME
   ```

Do not use broad config, release, or log commands for this cleanup. Do not remove these keys before
the deployed release no longer depends on them.

### Rollback

Rollback must not restore usable historical demo access. If application code is rolled back, keep
the historical identity inactive with zero Sessions, do not invoke the restored `demo:reset` task,
and do not restore the retired configuration keys. No database rollback is needed for this change.
Prefer a forward fix if the release has a problem.

## Known Test-Identity Verification

The historical seed created predictable Admin and Captain test identities. This is separate from
the retired Build Week account, and the #153 protections remain in force. Run this privacy-minimized
inspection separately against each confirmed staging and production app; it prints record IDs,
roles, active state, and session counts, but not passwords or email addresses:

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
attachments. Verify afterward that the user is inactive, has no Sessions, and cannot authenticate.
Deployed staging/production verification and remediation remain owner-operated and pending until
their results are recorded without sensitive values.

## Manual Regression Checks

- Development: `db:prepare` and `db:seed` succeed without creating users or printing credentials.
- Task surface: `bin/rails -T` does not list `demo:reset` or another demo population task.
- Authentication: normal active users can sign in; the retired inactive identity cannot.
- Production safety: rely on automated production-environment coverage. Do not run a destructive
  production command to test the guard.
