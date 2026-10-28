# Operational Monitoring

Boat Binder uses one application-level operational health path. `Operations::HealthMonitorJob`
runs every 15 minutes through the existing Solid Queue recurring scheduler and sends a direct email
through the existing SMTP configuration when it detects an unhealthy condition.

The operator who owns the configured operational-alert mailbox owns first response, safe
investigation, and escalation. Failed jobs are not retried or deleted automatically, and attachment
scan state is never changed by monitoring.

## Application-observable alerts

The monitor reports:

- failed Solid Queue executions, grouped by sanitized job class with counts and first/most-recent
  failure timestamps;
- failed `AttachmentScan` rows completed within the last seven days, grouped by the model's
  bounded status codes; and
- pending attachment scans older than the 15-minute polling window plus a 10-minute recurring
  recovery allowance.

This single failed-job path naturally covers `Storage::AttachmentScanJob`,
`Storage::RecoverStaleAttachmentScansJob`, and `Storage::PurgeUnattachedBlobsJob`. The monitor does
not call GuardDuty, rescan files, retry or discard jobs, purge blobs, or alter file availability.

Alert content excludes serialized job arguments, raw exception messages and backtraces, record or
blob identifiers, filenames, object keys, signed IDs, provider payloads, email configuration,
customer data, and vessel data. Investigators must keep those values out of public issues and shared
logs as well.

Solid Cache stores a structural fingerprint after successful delivery. The fingerprint includes
health categories, sanitized failed-job classes, failed-scan status categories, and coarse growth
buckets (`1`, `2-9`, `10-99`, and `100+`). Exact counts and timestamps remain in the email but
cannot churn the fingerprint. The same failure shape and growth bucket is suppressed for 24 hours,
after which it can produce a reminder; a new job class, status category, health category, or growth
bucket can alert sooner. Cache loss can cause a duplicate but cannot make an unhealthy query appear
healthy.

A successful monitor run reports failed prior `Operations::HealthMonitorJob` executions through the
same failed-job path. SMTP failures caught during the current run are logged with exception class
only, do not create a suppression fingerprint, and do not deliberately fail the monitor job. This
avoids recursive queue-failure noise while allowing the next run to try delivery again. This
application-level monitor cannot detect complete Solid Queue worker failure, recurring scheduler
failure, or `Operations::HealthMonitorJob` failing on every execution such that no successful run
remains to report prior failures. All three require a separately approved external heartbeat or
control-plane check.

If `OPERATIONAL_ALERT_RECIPIENT` is missing, the job records a sanitized configuration error and
does not send. Do not derive this recipient from customer or administrator records.

## Response and remediation

Investigate the underlying job failure before removing failed execution records, and preserve only
the minimum evidence needed to diagnose the cause. Do not copy job arguments, raw exception text,
customer data, filenames, object keys, or production identifiers into public issues or shared
evidence.

Do not change an `AttachmentScan` from `failed` to `clean` or `trusted_existing` merely to clear an
alert. `AttachmentScan` is authoritative security history, while the operational monitor covers
actionable, recent incidents. It uses `completed_at` to include failures from the last seven days;
an unexpected nil completion time safely falls back to `updated_at` for alert-window evaluation.
When a failure ages out of operational alerts, its scan row remains unchanged: aging out does not
resolve the failure, make the attachment available, or alter the fail-closed availability boundary.
Failed scan rows can remain as historical and security state after the operational cause is resolved
and must not be altered solely for alert suppression.

After the root cause is understood and resolved, failed queue records may be cleared through Solid
Queue's supported operational path. Escalation must use sanitized job classes, status categories,
counts, and timestamps suitable for this public repository.

## Storage-health boundary

The application database can safely provide Active Storage blob count and aggregate `byte_size`.
The repository cannot establish that the application's existing S3 identity has bucket-list or
cloud-metrics permissions: ordinary key-based Active Storage reads, writes, and deletes do not prove
either permission. The monitor therefore does not enumerate S3, log object keys, or broaden IAM.

Until a separate provider-side monitor is approved, the infrastructure owner must periodically
compare the database aggregates with provider-side current-object count and bytes and alert on a
sustained, material change from the established trend. Exact equality is not a health invariant:
stored variants, uploads or deletes in flight, incomplete multipart uploads, versioning,
noncurrent versions, and delete markers can all create legitimate differences. Metrics that include
all versions must not be compared directly with current Active Storage blob totals.

The narrow follow-up is either:

1. configure aggregate bucket count/size alarms in the existing AWS account, outside the Rails
   process; or
2. approve a narrowly reviewed monitoring identity and the minimum metrics or current-object-list
   permission needed for an automated aggregate comparison.

Both options require owner review of IAM scope, alert ownership, expected thresholds, and any AWS
metric cost. The application identity must not gain permissions implicitly for this issue.

## Managed-backup boundary

Heroku's backup schedule and capture history are control-plane state; they are not represented in
the Boat Binder database. Heroku also documents that scheduled PGBackup failures do not send native
failure notifications and that attachment changes can detach a schedule. Giving the Rails process
a Heroku credential would expand a customer-data application credential into the deployment control
plane, so this implementation does not do that.

The external managed-backup monitor is implemented by
`.github/workflows/managed-backup-monitor.yml` and `script/managed_backup_monitor`. It runs at
minute 17 twice daily and can also be dispatched manually. The monitor uses direct HTTPS GETs only;
it does not install the Heroku CLI, run inside Rails, create or restore backups, change schedules,
or persist provider responses. GitHub Actions job failure is the operator-visible alert. The owner
must enable the appropriate GitHub Actions failure notifications for the repository. Scheduled
workflow notifications are associated with the user who created the scheduled workflow; if another
user changes its cron syntax, notification ownership can move to that user. Ensure the owner account
remains the intended recipient for failure notifications. Scheduled GitHub Actions runs can be
delayed, and GitHub can disable scheduled workflows in a public repository after prolonged
inactivity. This check is therefore not a complete dead-man monitor. That limitation is accepted
for the current launch scope. Once per month, verify in the GitHub Actions tab that the
managed-backup monitor has recent scheduled runs.

The monitor job uses the protected GitHub Environment `production-monitoring` and requires two
owner-supplied values stored in that Environment:

- Environment secret `HEROKU_MANAGED_BACKUP_MONITOR_TOKEN`, containing an OAuth authorization with
  scope exactly `read-protected`; and
- Environment variable `HEROKU_MANAGED_BACKUP_MONITOR_APP`, containing the production app
  reference.

The permanent authorization belongs to the dedicated Heroku identity that is limited to Boat
Binder production, not the owner's primary Heroku account. `read` cannot retrieve the required
transfer history, while `read-protected` can. `global` must not be used. Although it is read-only,
`read-protected` can read protected runtime configuration, including highly sensitive production
values such as database connection strings and other application secrets. Compromise of this
GitHub Actions credential is therefore a material security event. The dedicated identity and its
production-only Boat Binder app access reduce the blast radius. The permanent token must be stored
only in the protected `production-monitoring` Environment, and Codex or other agents must never
receive it.

To rotate the credential, the owner creates a replacement `read-protected` authorization while
signed in as the dedicated identity, replaces the Environment secret without exposing it in logs
or issues, verifies a healthy manual workflow run, and then revokes the prior authorization.
Removing the monitor requires revoking its authorization as well as deleting the Environment
secret.

Each run resolves the current `DATABASE` attachment, requires exactly one recurring schedule,
correlates scheduled captures using the schedule UUID, filters backup transfers from restores and
copies, and loads verbose detail for at most the ten newest relevant transfers. Running transfers
are skipped, and the newest completed scheduled transfer determines health: failure is unhealthy,
while success is checked for freshness. If no completed transfer can be established within the
bounded lookup, the monitor fails closed as stale. The freshness threshold is 30 hours: the
expected daily cadence plus six hours for ordinary schedule variation and capture duration. A
small future timestamp skew of at most five minutes is tolerated. Transient network failures, HTTP
429, and HTTP 5xx responses receive one short retry; authorization, schema, and backup-health
failures are not retried.

Healthy runs log only `managed_backup_monitor result=healthy`. Unhealthy runs fail with one of these
sanitized categories:

- `database_resolution_failed`;
- `schedule_missing`;
- `schedule_ambiguous`;
- `scheduled_capture_failed`;
- `freshness_stale`;
- `authorization_failed`;
- `schema_error`; or
- `check_error`.

Logs exclude tokens, authorization headers, response bodies, app and resource identifiers, URLs,
timestamps, backup metadata, and customer data. Do not copy raw production responses or operational
inventory into this public repository, issues, or pull requests.

The following are accepted constraints rather than implementation blockers:

1. Boat Binder currently uses a Personal Heroku account, so the dedicated collaborator has broader
   in-app permissions than ideal. A paid Heroku Team is not being adopted solely for this monitor.
2. The automation credential itself is limited to `read-protected`, and the dedicated identity is
   limited to Boat Binder production.
3. The Heroku Data API endpoints used by the official CLI do not have the same documented public
   contract as Platform API v3. Any endpoint or schema change therefore fails the monitor closed.

### Owner setup and first production run

The workflow intentionally does not treat missing configuration as healthy. Complete setup in this
order:

1. Merge PR #290 through the normal required-review and required-CI workflow.
2. Create the GitHub Environment `production-monitoring`.
3. Restrict that Environment's deployment branches to `main`. Do not add required reviewers,
   because scheduled checks must run unattended.
4. While signed in as the dedicated monitoring identity, create the permanent Heroku OAuth
   authorization with scope exactly `read-protected`.
5. Store the token directly in the Environment secret
   `HEROKU_MANAGED_BACKUP_MONITOR_TOKEN`.
6. Store the production app reference in the Environment variable
   `HEROKU_MANAGED_BACKUP_MONITOR_APP`.
7. Never provide either production value to Codex or another agent.
8. Enable appropriate GitHub Actions failure notifications.
9. From `main`, manually dispatch the first production monitor run.
10. Confirm the run reports only the sanitized healthy result before considering #229 complete.

GitHub can automatically create a referenced Environment without protection rules if it does not
already exist. The owner must therefore complete Environment creation and the `main` restriction
before placing any secrets into it.

A scheduled run can occur between merge and owner setup. An initial red run is expected if the
Environment or required values are not yet configured; complete setup and verify a subsequent
manual run rather than weakening the fail-closed behavior.

The existing required pull request, human review, ruleset, required CI, and no-bypass protections
remain the authoritative repository security controls. A paid Heroku Team is not being adopted
solely for this monitor.

See Heroku's [OAuth documentation](https://devcenter.heroku.com/articles/oauth) for the scope model
and its warning that read-only resources can still expose sensitive metadata. See its
[PGBackups documentation](https://devcenter.heroku.com/articles/heroku-postgres-backups) for the
schedule, status, and notification limitations.
