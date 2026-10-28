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
- failed `AttachmentScan` rows, grouped by the model's bounded status codes; and
- pending attachment scans older than the 15-minute polling window plus the five-minute recurring
  recovery allowance.

This single failed-job path naturally covers `Storage::AttachmentScanJob`,
`Storage::RecoverStaleAttachmentScansJob`, and `Storage::PurgeUnattachedBlobsJob`. The monitor does
not call GuardDuty, rescan files, retry or discard jobs, purge blobs, or alter file availability.

Alert content excludes serialized job arguments, raw exception messages and backtraces, record or
blob identifiers, filenames, object keys, signed IDs, provider payloads, email configuration,
customer data, and vessel data. Investigators must keep those values out of public issues and shared
logs as well.

Solid Cache stores a fingerprint after successful delivery. An unchanged condition is suppressed
for 24 hours, after which it can produce a reminder. A changed count, job class, status category, or
timestamp produces a new fingerprint and can alert sooner. Cache loss can cause a duplicate but
cannot make an unhealthy query appear healthy. The monitor excludes its own failed executions to
prevent a delivery or rendering failure from recursively alerting on itself; delivery and cache
failures are logged with exception class only.

If `OPERATIONAL_ALERT_RECIPIENT` is missing, the job records a sanitized configuration error and
does not send. Do not derive this recipient from customer or administrator records.

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

The remaining #229 acceptance criterion requires an approved external check for schedule presence,
latest scheduled-capture success, and freshness within the daily cadence plus an owner-approved
grace period. The smallest options are:

- a scheduled GitHub Actions check using a dedicated Heroku identity/token stored as a repository
  secret; a public-repository scheduled run can have no incremental Actions fee within GitHub's
  included allowance, but Heroku Platform API OAuth scope is broad (`global`), so the identity's app
  access and secret rotation require explicit approval; or
- a third-party Heroku monitoring/add-on plan, with recurring vendor cost and a separate security,
  data handling, and credential review. A service that replaces or duplicates the established
  backup system is out of scope.

For the MVP, prefer the first option only after the owner approves the external workflow and the
least-access Heroku identity available. Manual verification remains an interim control, not closure
of the automated backup-freshness criterion. See Heroku's
[PGBackups documentation](https://devcenter.heroku.com/articles/heroku-postgres-backups) for the
schedule, status, and notification limitations.
