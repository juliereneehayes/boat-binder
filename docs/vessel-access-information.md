# Vessel access information foundation

This document describes the security foundation introduced by issue #255. It intentionally does not
provide the customer-facing Access & Operations experience planned for issue #256.

## Authority and authorization

`ManagedServiceRelationship` is the only authority for whether an Account has an HYC Managed
Service relationship. It is independent of `Subscription`, Stripe identifiers, Account names,
roles, and browser/session state. A relationship is effective only when both the relationship and
its Account are active.

`Authorization::RestrictedVesselPolicy` is the reusable server-side decision for restricted Vessel
reads and writes. Controller scopes and the persistence service use this same policy.

| Account state | Admin | Captain | Owner |
| --- | --- | --- | --- |
| Effective Managed Service | Read/write | Read/write | Active membership reads; active editor membership writes |
| Self Managed or no effective Managed Service | Denied | Denied | Existing Self Managed lifecycle, owner-limit, and membership rules |

Managed Service Owner access does not depend on legacy, starter, professional, or Self Managed
subscription state. Multiple active Owners may receive access through their own active memberships.
Self Managed access continues to use `Billing::SelfManagedEntitlement` and
`Billing::OwnerUserLimit`; those policies are not weakened or duplicated as Managed Service state.

Every lookup remains scoped to the authorized Account and Vessel. A membership on one Account does
not authorize another Account, including when a User has memberships at different access levels on
multiple Accounts.

## Controlled relationship transitions

There is no public relationship-management route or billing workflow. An authenticated internal
operation may call:

```ruby
ManagedServiceRelationship::Transition.call!(
  account:,
  active: true_or_false,
  actor: current_admin,
  request_id:
)
```

The operation requires an active persisted Admin, serializes on the Account, and records either
`managed_service_relationship.activated` or `managed_service_relationship.revoked`. Repeating the
current state is a no-op. Requesting revocation when no relationship exists is also a no-op: it does
not create an inactive relationship or a misleading revocation event. Revocation affects the next
authorization decision immediately and does not delete the Account, Vessel, or encrypted
information.

Console operators must pass their own authenticated, active Admin identity as `actor`; shared,
impersonated, or placeholder identities do not provide acceptable attribution. Unauthorized
transition attempts are rejected before state changes. They are not recorded by this service
because it has no trusted request boundary from which to attribute a denied attempt; any future
public transition endpoint must define denial auditing at that authenticated boundary rather than
creating a parallel audit system here.

## Encrypted persistence and concurrency

`VesselAccessInformation` is a dedicated one-per-Vessel record. Account context is derived through
the Vessel; the record does not copy an Account identifier. `restricted_details` uses Rails Active
Record Encryption and is never stored in general `Asset` fields or indexed.

All application writes use `VesselAccessInformation::Persistence.save!`. The service:

- authorizes the actor through `Authorization::RestrictedVesselPolicy`;
- serializes writes under Vessel and Account row locks;
- reloads the canonical one-per-Vessel record inside the locks;
- validates presence and a 10,000-character maximum;
- treats only an unchanged persisted record as a no-op; and
- records create/update or denied-write audit events without the restricted value.

This prevents simultaneous first writes from producing multiple records or an avoidable uniqueness
error. Updates are serialized and operate on the current database record rather than a stale
association instance. This MVP does not implement credential version history or collaborative
field-level conflict resolution.

The Vessel row lock is also the Account-reassignment boundary. Ordinary cross-Account reassignment
is rejected whenever restricted information exists, including direct model updates and crafted
internal requests. The record remains encrypted and attached to its original Vessel and Account;
it is not decrypted, copied, silently transferred, or deleted. Reassignment remains supported for
Vessels without restricted information, and same-Account edits remain unchanged.

Any future transfer or clearance workflow requires separate product and security approval. It must
explicitly authorize both Account contexts, define credential-owner consent and audit semantics,
and preserve encryption throughout. Removing the guard, deleting the record, or copying decrypted
values to make an ordinary reassignment succeed is not a supported workaround.

## Encryption keys, backup, restore, and rotation

Restricted writes must remain disabled unless the existing Active Record Encryption configuration
is present in every process that may read or write the data. Encryption material must never be
stored in the repository, logs, audit records, support tickets, or exported files.

Database backups contain ciphertext. A usable restore requires the corresponding encryption keys
and derivation salt to be preserved through the separately controlled secrets backup process.
Losing those keys makes the restricted values unrecoverable.

Key rotation must use Rails-supported multi-key Active Record Encryption mechanisms:

1. retain the previous key for reads;
2. make the new key current for writes;
3. re-encrypt and verify affected records through an approved, separately reviewed operation; and
4. remove the previous key only after verification and rollback readiness.

Do not implement ad hoc decryption or custom cryptography for rotation.

## Audit and privacy boundaries

Security events use `SecurityAudit::Recorder` and contain only the action, outcome, actor identifier,
Account identifier, target identifier, request identifier, and approved changed-field names. They
never contain old/new restricted values. Consistent with the audit/privacy decision in #250, this
feature does not collect source IP in its audit operations.

Restricted parameter names are filtered from Rails logs. The persistence service does not log
decrypted values, pass them to background jobs, or emit telemetry containing them. Ordinary Vessel
pages, forms, model attributes, search, Documents, and jobs do not load or expose the restricted
record.

The current Account export/recovery workflow records review and fulfillment decisions only; it does
not generate or deliver files. Restricted Vessel information is excluded. Any future export must
define a separately authorized, explicit credential-export policy before including these values.

## Deletion and retention

Encrypted access information is not silently deleted with a Vessel. A Vessel containing such a
record is retained, and the supported Vessel deletion action returns a controlled explanation.
Operators must not remove the encrypted child record merely to make deletion succeed.

Likewise, an Account with a Managed Service relationship is protected from model-level deletion.
There is currently no supported Account-deletion route. A broader retention, offboarding, or
credential-destruction policy requires separate product and security approval; it is not part of
#255.

## Migration and rollback

The migration is additive: it creates the Managed Service relationship and encrypted Vessel access
tables without backfilling plaintext. Deploy the schema before enabling any controlled writes.

Rollback may drop the tables only while both are empty. Once relationship or encrypted records
exist, rollback raises and leaves the data in place. Rollback must never decrypt, copy to plaintext,
or delete restricted values.

## Deployment verification

Before accepting restricted data:

1. confirm the additive migration completed;
2. confirm Active Record Encryption configuration loads without printing key material;
3. verify Managed Service activation and revocation with synthetic data and attributed audit events;
4. verify Admin, Captain, Owner, inactive-user, read-only, Self Managed, and cross-Account decisions;
5. verify ciphertext differs from the synthetic plaintext in the database;
6. verify ordinary Vessel, Document, search, job, export-review, and audit paths exclude the value;
7. verify deletion protection is handled without an unhandled error; and
8. verify backup/restore and key-custody procedures preserve required encryption material.

## MVP limitations and collection gate

This foundation contains one internal representative encrypted field. It does not provide a reveal
flow, customer UI, final credential schema, external sharing, Captain assignment, per-field ACL,
Managed Service billing automation, credential versioning, or a general retention workflow.

**Real customer credentials must not be collected or stored until issue #256 is implemented,
reviewed, deployed, and verified.** Only synthetic test values are permitted during #255 validation.
