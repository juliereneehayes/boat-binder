# Attachment Security and Operations

Boat Binder disables Rails' default Active Storage routes. Documents, vessel primary photos, and
service-visit photos are streamed through resource-scoped Boat Binder routes. Each request reruns
the application's authentication, active-user, Account membership, Account state, role, and
subscription-lifecycle checks before resolving the attachment from its owning record. Responses
are private and non-cacheable. The application does not issue storage-service URLs, so revocation
takes effect on the next request to the same Boat Binder URL.

Uploads remain server-mediated multipart form submissions. The controllers reject signed blob IDs
and other non-upload values instead of treating possession of an Active Storage identifier as
permission to attach it. Existing blob, attachment, and object-storage records require no migration
or copy.

Before attaching, the application inspects file contents with Marcel and requires each filename
extension to match the detected MIME type. Documents accept PDF, JPEG, PNG, and WEBP files up to
25 MB. Vessel primary photos accept JPEG, PNG, and WEBP files up to 10 MB. Each service-visit photo
has the same 10 MB limit; one submission may contain at most 10 photos totaling at most 50 MB. The
entire submitted service-visit photo set is checked before any new photo is attached, so one invalid
file rejects all new photos and leaves existing photos unchanged. These controls do not include
malware scanning or quarantine.

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
