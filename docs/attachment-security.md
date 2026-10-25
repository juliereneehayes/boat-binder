# Attachment Security and Operations

Boat Binder disables Rails' default Active Storage routes. Documents, vessel primary photos, and
service-visit photos are streamed through resource-scoped Boat Binder routes. Each request reruns
the application's authentication, active-user, Account membership, Account state, role, and
subscription-lifecycle checks before resolving the attachment from its owning record. Responses
are private and non-cacheable. The application does not issue storage-service URLs, so revocation
takes effect on the next request to the same Boat Binder URL.

Uploads remain server-mediated multipart form submissions. The controllers reject signed blob IDs
and other non-upload values instead of treating possession of an Active Storage identifier as
permission to attach it. The existing private Active Storage object is also the quarantined object;
the application does not copy uploads to another bucket or expose a second storage path.

Before attaching, the application inspects file contents with Marcel and requires each filename
extension to match the detected MIME type. Documents accept PDF, JPEG, PNG, and WEBP files up to
25 MB. Vessel primary photos accept JPEG, PNG, and WEBP files up to 10 MB. Each service-visit photo
has the same 10 MB limit; one submission may contain at most 10 photos totaling at most 50 MB. The
entire submitted service-visit photo set is checked before any new photo is attached, so one invalid
file rejects all new photos and leaves existing photos unchanged.

## Malware scan quarantine

AWS GuardDuty Malware Protection for S3 scans new objects independently of the Rails process. For
every newly accepted or replaced Document file, vessel primary photo, and service-visit photo, Boat
Binder creates one `AttachmentScan` row for the Active Storage blob in `pending` state. A Solid
Queue job reads the GuardDuty-managed `GuardDutyMalwareScanStatus` object tag for up to 15 minutes.
The initial check is immediate. A missing tag schedules checks after 5, 10, 15, and 30 seconds,
then every 60 seconds for the remainder of the window; the final wait is capped at the 15-minute
deadline. The application identity reads tags but never writes or replaces that managed tag.

Local development still creates ordinary `AttachmentScan` rows and runs the same scan job, but the
provider boundary returns a simulated `NO_THREATS_FOUND` result only when
`Rails.env.development?` is true and the blob uses Active Storage Disk storage. This keeps ordinary
Disk-backed development uploads usable while exercising the real quarantine state transition. The
simulation provides no malware protection. Development configured for S3 reads the real GuardDuty
tag. Test, staging, and production do not use this shortcut; unsupported non-S3 storage in those
environments fails closed and no environment variable or storage configuration can enable it.

The provider mapping is intentionally closed and exact:

- `NO_THREATS_FOUND` becomes `clean`;
- `THREATS_FOUND` becomes `rejected` and creates one minimized
  `attachment.malware_rejected` security audit event;
- `UNSUPPORTED`, `ACCESS_DENIED`, and `FAILED` become `failed`;
- an absent tag remains `pending` until the bounded polling window expires, then becomes `failed`;
  and
- any unknown value becomes `failed`.

Only `clean` and `trusted_existing` blobs can be streamed or rendered. Missing rows, `pending`,
`failed`, and `rejected` all fail closed at the existing authenticated attachment routes. The gate
runs after the normal resource scope, membership, Account state, role, and subscription checks, so
scan state does not weaken tenant isolation. The same gate prevents image rendering; Boat Binder
does not create variants or previews for an unavailable attachment. Active Storage content analyzers
and previewers are disabled because the application does not use their metadata or output and they
would otherwise read image/PDF bytes before scan approval. Any future attachment processor must
check approved scan state before reading content. Rejected objects remain in the private bucket and
may remain attached for investigation or later operator action; this phase does not add a purge
workflow.

GET pages that render a `pending` attachment add one browser-side refresh timer. The timer checks
every five seconds during the pending scan's first minute, then every 30 seconds, and stops at the
existing 15-minute scan deadline. It pauses while the document is hidden, while an editable form
control has focus, or after a form emits an `input` or `change` event. Non-GET responses, including
validation re-renders, never include the controller. An unsafe refresh is skipped rather than
submitting, copying, or persisting the user's draft.

Each safe refresh uses Turbo to revisit the same authenticated page URL, so it repeats that page's
existing authentication, Account scope, lifecycle, and authorization checks. The server-rendered
scan state remains authoritative: pending bytes are never requested or displayed, and the timer
disappears as soon as no rendered attachment remains pending. There is no separate status or
attachment-delivery endpoint, and the browser receives no provider status, object key, bucket, or
scan details. This improves ordinary completion feedback but does not promise a fixed GuardDuty
completion time.

The rollout migration creates exactly one `trusted_existing` row for each blob attached when the
migration runs. Those attachments remain available without rescan or bulk Active Storage metadata
updates. Unattached blobs are not grandfathered and continue to be handled by the existing stale
blob cleanup. `trusted_existing` is the approved compatibility/rollout disposition for an attachment
that existed before GuardDuty enforcement and was intentionally grandfathered without malware
scanning. It is not evidence that GuardDuty scanned the file or that the file was proven clean.

The production recurring schedule runs `Storage::RecoverStaleAttachmentScansJob` every five minutes.
It finds only `pending` scans created more than the 15-minute polling window ago and invokes the
existing authoritative scan job once for each candidate. The final reconciliation reads the current
GuardDuty tag: clean and threat results retain their normal mapping, provider terminal results fail
closed, and a still-absent tag becomes `failed` with `SCAN_TIMEOUT`. This recovers scans whose
scheduled poll was lost without duplicating provider mapping or reading object contents. A concurrent
normal poll or overlapping recovery run cannot overwrite a terminal state, repeated recovery is
idempotent, and the final check cannot schedule another poll after the deadline. Expected terminal
failures are processed across the batch before the recurring execution raises one safe aggregate
failure for the existing #113/#229 failed-job monitoring.
Do not disable Solid Queue recurring tasks in production, including through
`SOLID_QUEUE_SKIP_RECURRING`.

Scan records contain only the blob database ID, state, provider identifier, check count, timestamps,
and an allowlisted status/failure code. They do not store object keys, filenames, customer or Account
data, raw provider responses, or threat details. Operational logs use only scan/blob database IDs,
allowlisted status codes, and exception class names. Do not paste Solid Queue arguments, object
keys, filenames, or provider payloads into tickets or shared logs.

## AWS prerequisites

Complete these separately for staging and production before deploying scan-aware application code:

1. Enable GuardDuty Malware Protection for S3 for the exact private bucket and Active Storage prefix
   used by that environment. GuardDuty's service role must be able to scan objects and write its
   managed result tag.
2. Grant the Boat Binder runtime identity `s3:GetObjectTagging` for those objects. Do not grant or
   add `s3:PutObjectTagging` for this feature.
3. Confirm the environment still uses the existing `amazon` Active Storage service and private
   bucket. Do not introduce a second bucket, Lambda, EventBridge rule, webhook, or scanner.
4. Confirm the Solid Queue worker is running and the `background` queue is serviced.
5. Confirm GuardDuty can add the managed tag under the bucket's tag, encryption, ownership, and
   access policies. A scan result that cannot be read fails closed.

## Deployment order

Use staging first, then repeat the same sequence in production. Keep uploads paused from immediately
before the release migration until the scan-aware web release is serving requests:

1. Enable and verify the GuardDuty plan and read-only application tag permission.
2. Verify the Solid Queue worker and failed-execution monitoring.
3. Deploy the migration and application code together. The release migration backfills attached
   blobs as `trusted_existing`; it does not enqueue rescans.
4. Before resuming uploads, compare attached blob database IDs with `attachment_scans` and reconcile
   any attached blob missing a scan row after the migration/backfill boundary by registering it as
   `pending` and enqueueing the normal scan job. Let the GuardDuty tag decide its disposition; do not
   guess whether it deserves trust or use a blanket `trusted_existing` repair. Use only database IDs
   and timestamps during reconciliation, and do not inspect file contents, names, object keys, or
   customer metadata. Genuinely stale unattached blobs remain outside this reconciliation and are
   left to the existing cleanup job. Missing scan state remains unavailable throughout.
5. Verify the migration and reconciliation completed before allowing the new web release to accept
   uploads.
6. Upload one new benign fixture and complete the manual checks below.
7. Promote the same reviewed revision to production and repeat the worker, migration, reconciliation,
   and benign
   upload checks before declaring rollout complete.

Do not roll back to code that serves attachments without consulting scan state after new uploads
have been accepted. That would make pending, failed, or rejected objects available. Prefer a forward
fix. The scan migration is intentionally irreversible: normal migration rollback refuses to drop
`attachment_scans` because it contains authoritative security disposition. During application
rollback or recovery, keep the scan-state table and the scan-aware delivery gate deployed. Never
restore attachment access by deleting scan disposition state. If an emergency application rollback
is unavoidable, stop attachment uploads and keep the gate active until every post-rollout blob has
an operator-verified safe disposition.

## Manual staging verification

Do not commit an EICAR file or signature to this repository. Use ordinary generated fixtures for the
clean path. In staging only, the owner may use the standard harmless EICAR antivirus test string from
its authoritative source through an approved GuardDuty test procedure; delete it after verification
and never use customer data or production storage for that check.

1. Upload a new Document, vessel primary photo, and service-visit photo. Confirm each has one
   `pending` scan row and a queued/running scan job, using database IDs only.
2. Before GuardDuty completes, confirm the UI says `Processing`, offers no open/download action or
   image, and the protected route returns not found. Do not use a Rails console script to advance
   scan state.
3. After GuardDuty writes `NO_THREATS_FOUND`, confirm the page updates automatically, the row becomes
   `clean`, and the same protected route works with private/no-store/nosniff headers. Record the
   approximate observed time for internal validation only; do not present it as an SLA.
4. Confirm a pre-rollout attachment has one `trusted_existing` row and remains accessible without a
   scan job.
5. With a second staging Account, confirm its user cannot read or infer any attachment from the first
   Account, regardless of scan state.
6. Upload the standard EICAR test file only under the staging procedure above. Confirm it becomes
   `rejected`, has no normal download/image path, shows the approved rejection copy, and creates one
   minimized audit event. Do not inspect or persist threat details.
7. Exercise provider/failure UI and timeout behavior through the automated stubbed boundary unless a
   separate owner-approved staging failure test is available.
8. Repeat the #274 mixed valid/invalid atomic rejection check and a #275 Service Visit workflow edit;
   confirm no scan rows are created for rejected uploads and existing photos remain intact.
9. Review failed Solid Queue executions and aggregate scan counts by status. Do not inspect or copy
   serialized job arguments into shared systems.

Also confirm the recurring stale-scan recovery task is loaded in staging and production. A test scan
left `pending` beyond the polling window must receive one final GuardDuty reconciliation. Confirm a
current clean tag becomes `clean`, a threat tag becomes `rejected`, and a still-absent tag becomes
`failed` with `SCAN_TIMEOUT`; each state must retain its normal availability and safe operational
visibility.

`Storage::PurgeUnattachedBlobsJob` runs daily through the production Solid Queue recurring schedule.
It purges only blobs that are still unattached and were created more than 24 hours earlier. The job
rechecks attachment state while locking each candidate, logs the blob database ID and exception on
failure, and re-raises so the failed Solid Queue execution remains observable.

## Owner-operated storage checks

Production uses the S3-compatible `amazon` service configured in `config/storage.yml`; this
repository does not own bucket lifecycle policies or cloud usage alarms. The infrastructure owner
must verify these independently:

- enable bucket-size and request-cost monitoring, alerting on an unexpected sustained increase
  relative to normal upload volume;
- configure incomplete multipart-upload cleanup after a conservative period (at least 24 hours),
  without expiring live application objects;
- confirm object versioning/retention choices do not retain deleted customer files longer than the
  documented data-retention policy; and
- alert on recurring cleanup-job failures and periodically compare S3 usage with Active Storage blob
  totals.

Rollback to code that restores default Active Storage routes would restore permanent bearer-style
application URLs. Treat that as a security regression and prefer a forward fix. Existing files do
not need to be reuploaded during deployment or rollback.
