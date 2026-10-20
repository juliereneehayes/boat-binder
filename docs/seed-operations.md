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
only record IDs, roles, membership/active/session state, or configuration-key presence. They do not
print credential values.

1. Before deployment, use the historical Account marker only to discover records that may need
   independent provenance review:

   ```sh
   heroku run 'bin/rails runner '\''marker = "[Build Week demo account]"; Account.where("notes LIKE ?", "%#{Account.sanitize_sql_like(marker)}%").order(:id).find_each { |account| account.account_memberships.includes(:user).order(:id).find_each { |membership| user = membership.user; puts({ account_id: account.id, user_id: user.id, role: user.role, user_active: user.active?, sessions: user.sessions.count, access_level: membership.access_level, membership_active: membership.active?, marked_demo_account: true }.to_json) } }'\''' --app APP_NAME
   ```

   An Account marker, membership in that Account, or a User resolved from the obsolete
   `BUILD_WEEK_DEMO_EMAIL` value is a discovery signal only. None proves that the User is the
   historical contest identity. Do not retrieve or print the configured email value merely to make
   this association.

   Mutate an identity only when independent operational evidence positively proves it is the retired
   contest identity. Then confirm it is inactive with zero Sessions. When provenance is ambiguous,
   preserve the User, role, memberships, credentials, and Sessions; record identity retirement as
   not applicable or unable to prove. Never deactivate every User associated with the marked Account
   or the User that happens to match stale configuration.

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

   Listing only keys previously confirmed present is preferred. Passing an already-absent key to
   `heroku config:unset` is harmless.

Do not use broad config, release, or log commands for this cleanup. Do not remove these keys before
the deployed release no longer depends on them. Removing obsolete configuration disables the old
setup path; it does not identify, delete, deactivate, or otherwise mutate a User whose email may
happen to match a stale value. The marked Account and its fictional data may remain.

### Completion Criteria

#125 is operationally complete when the obsolete setup/reset runtime is gone, obsolete Build Week
configuration is removed after deployment, and no positively identified historical contest identity
remains active with usable Sessions or credentials. An ambiguous identity is preserved rather than
modified and recorded as not applicable or unable to prove. Production has an independently
identified historical identity that is already inactive with zero Sessions; current staging evidence
does not positively identify the historical Owner created by the retired setup service.

### Rollback

Rollback must not restore usable historical demo access. If application code is rolled back, keep
any positively identified historical identity inactive with zero Sessions, leave ambiguous Users
unchanged, do not invoke the restored `demo:reset` task, and do not restore the retired configuration
keys. No database rollback is needed for this change. Prefer a forward fix if the release has a
problem.

## #153 Boundary

The historical seed created predictable Admin and Captain test identities. This is separate from
the retired Build Week runtime, and the #153 protections remain in force: ordinary seeds create no
users, production seeding is prohibited, and no predictable privileged credentials are restored.
This #125 runbook does not authorize mutation of Admin/Captain identities or other general test
accounts. Handle any positively identified general seed identity only through #153 review and
independent provenance evidence.

## Manual Regression Checks

- Development: `db:prepare` and `db:seed` succeed without creating users or printing credentials.
- Stale config: all four retired variables have no effect on ordinary seed behavior.
- Task surface: `bin/rails -T` does not list `demo:reset` or another demo population task.
- Authentication: normal active users can sign in; ambiguous identities remain unchanged.
- Production safety: rely on automated production-environment coverage. Do not run a destructive
  production command to test the guard.
