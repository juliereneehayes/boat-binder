# Vessel Access & Operations

This document describes the restricted Vessel access foundation introduced by issue #255 and the
customer-facing Access & Operations experience introduced by issue #256. Restricted credentials and
ordinary operating instructions share one profile section but intentionally use separate storage,
authorization, persistence, and controller boundaries.

## Authority and authorization

`ManagedServiceRelationship` is the only authority for whether an Account has an HYC Managed Service
relationship. It is independent of `Subscription`, Stripe identifiers, Account names, roles, and
browser/session state. A relationship is effective only when both the relationship and Account are
active.

`Authorization::RestrictedVesselPolicy` is the reusable server-side decision for every restricted
read, reveal, and write.

| Account state | Admin | Captain | Owner |
| --- | --- | --- | --- |
| Effective Managed Service | Read/write | Read/write | Active membership reads; active editor membership writes |
| Self Managed or no effective Managed Service | Denied | Denied | Existing Self Managed lifecycle, owner-limit, and membership rules |

Managed Service Owner access does not depend on legacy, starter, professional, or Self Managed
subscription state. Self Managed access continues to use `Billing::SelfManagedEntitlement`,
`Billing::OwnerUserLimit`, and `Authorization::SelfManagedOwnerPolicy`; those rules are not duplicated
or weakened. Membership on one Account never authorizes another Account.

Ordinary Vessel Operations fields continue to use existing Vessel authorization:

| User state | Read operations | Edit operations |
| --- | --- | --- |
| Active Admin or Captain with ordinary Vessel visibility | Yes | Yes |
| Active Owner with an authorized Account membership and readable lifecycle | Yes | Active editor membership with a qualifying write entitlement only |
| Read-only Owner | Yes while the existing readable lifecycle allows | No |
| Inactive User, Account, or membership; revoked or unrelated Account | No | No |

The Access & Operations section appears only after the ordinary Vessel lookup succeeds. Restricted
controls then make a separate central-policy decision; ordinary Admin/Captain Vessel visibility never
implies restricted access to a Self Managed Vessel.

## Field classification

Restricted values are stored only in the encrypted record:

- Marina gate/access code
- Marina access instructions
- Physical key location
- Lockbox code
- Alarm/security code
- Additional vessel access notes

Ordinary Vessel information is stored as nullable text on `Asset`:

- Engine startup instructions
- Engine shutdown instructions
- Battery and shore-power instructions
- Additional operating notes

Routine instructions render as escaped text and are not included in Vessel search. The interface tells
users to put passwords, codes, key locations, and other sensitive access details in restricted fields
rather than ordinary notes. Neither group is added to analytics, notifications, jobs, Documents,
Service Visits, or the current export-review workflow.

## Controlled Managed Service transitions

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

The operation requires an active persisted Admin, serializes on the Account, and records an activation
or revocation. Repeating the current state is a no-op. Revocation when no relationship exists is also a
no-op: it creates neither an inactive relationship nor a false audit event. Revocation affects the next
authorization decision and never deletes the Account, Vessel, or encrypted information.

Console operators must attribute transitions to their own authenticated, active Admin identity.
Unauthorized transition attempts are rejected before state changes. They are not recorded by this
service because it lacks a trusted request boundary for attribution; a future public endpoint must
define denial auditing at its authenticated boundary.

## Encrypted representation and concurrency

`VesselAccessInformation` remains the dedicated one-per-Vessel record. Account context is derived
through the Vessel; the record does not copy an Account identifier. `restricted_details` uses Rails
Active Record Encryption and is never stored in general `Asset` fields or indexed.

Issue #256 stores a schema-identified, deterministic versioned JSON document inside the existing encrypted attribute. It
does not add plaintext credential columns, a second table, or custom cryptography. Each supported field
is independently replaceable or clearable. Existing pre-#256 raw encrypted values remain readable and
are treated as `additional_vessel_access_notes` when first used through the field-aware interface; no
destructive backfill is required.

All application writes use `VesselAccessInformation::Persistence`. The legacy `save!` entrypoint keeps
the verified #255 encrypted serialization path. The customer interface uses `update_fields!`, which:

- authorizes through `Authorization::RestrictedVesselPolicy`;
- serializes changes under the existing Vessel and Account row locks;
- reloads the canonical one-per-Vessel record inside those locks;
- supports explicit Keep Existing, Replace, and Clear operations;
- preserves untouched fields during partial and concurrent updates;
- validates bounded optional values before persistence; and
- records create, update, field-clear, or denied-write events without values.

Blank and unrelated inputs cannot overwrite stored values. Replacement never requires returning the
previous value to the browser. Clearing the final populated field removes the empty record only as the
result of that explicit authorized clearance request. Lifecycle transitions, ordinary Vessel edits,
deletion, and reassignment never clear credentials.

This MVP does not implement credential version history or collaborative conflict presentation.

## Masking, reveal, and browser handling

Initial Vessel HTML contains only field labels, saved/not-set state, and masked placeholders. It never
contains restricted plaintext in visible content, hidden inputs, data attributes, or general JSON.
Restricted edit inputs are blank and use explicit operations.

Reveal is a POST-only action for one named field. `VesselAccessInformation::Revealer` reloads the
canonical Vessel, acquires the Vessel/Account locks, reevaluates central read authorization, loads only
the requested field, and records the reveal before returning it. The response is a narrow Turbo Frame
fragment with `Cache-Control: no-store`; it never returns the complete credential set.

Hide replaces the fragment with its masked state. A small Stimulus controller removes revealed text
before Turbo snapshots a page. Leaving the page removes the live DOM. Secrets are not written to URLs,
browser storage, analytics, logs, jobs, or audit metadata. Rails CSRF protection remains enabled for
reveal, hide, and write requests.

Authorization is reevaluated on every reveal and write, so Managed Service revocation and current
membership/entitlement state apply to the next request.

## Account isolation, reassignment, and deletion

The Vessel lock is also the Account-reassignment boundary. Ordinary cross-Account reassignment and
Asset-type changes are rejected whenever restricted information exists. The encrypted record remains
attached to its original Vessel and Account; it is not decrypted, copied, transferred, or silently
deleted. Reassignment remains supported for Vessels without restricted information, and same-Account
edits remain unchanged.

Encrypted access information is not silently deleted with a Vessel. A protected Vessel is retained,
and the supported deletion action returns a controlled explanation before destructive associations are
removed. An Account with a Managed Service relationship is likewise protected from model-level
deletion.

Any future cross-Account transfer, bulk clearance, offboarding, or retention workflow requires separate
product and security approval. It must authorize both Account contexts, define credential-owner consent
and audit semantics, and preserve encryption. Removing the guard or copying decrypted values is not a
supported workaround.

## Audit and privacy boundaries

Security events use `SecurityAudit::Recorder` and contain only the action, outcome, actor identifier,
Account identifier, target identifier, request identifier, and approved semantic field names. They
never contain old/new values or full request payloads. Consistent with #250, these operations do not
collect source IP.

Successful create, update, field-clear, and reveal events record only approved field names. Denied
writes and denied reveals are recorded when a safe Account context exists. A failed denial-audit write
cannot replace the original authorization denial, and operational logging contains only the audit
exception class.

The entire `restricted_fields` parameter subtree and legacy `restricted_details` name are filtered from
Rails logs. Services do not pass values to background jobs or telemetry. Ordinary Vessel pages, forms,
model attributes, search, Documents, Service Visits, notifications, and export-review pages do not
expose restricted values. Any future export needs a separately authorized credential-export policy.

## Encryption keys, backup, restore, and rotation

Restricted writes must remain disabled unless the existing Active Record Encryption configuration is
present in every process that may read or write the data. Encryption material must never be stored in
the repository, logs, audits, support tickets, or exported files.

Database backups contain ciphertext. A usable restore requires the corresponding encryption keys and
derivation salt from the separately controlled secrets backup. Losing those keys makes values
unrecoverable.

Key rotation must use Rails-supported multi-key Active Record Encryption:

1. Retain the previous key for reads.
2. Make the new key current for writes.
3. Re-encrypt and verify through an approved, separately reviewed operation.
4. Remove the previous key only after verification and rollback readiness.

Do not implement ad hoc decryption or custom cryptography.

## Migration, deployment order, and rollback

The #255 migration created the Managed Service relationship and encrypted access tables without a
plaintext backfill. The #256 migration adds four nullable ordinary instruction columns to `assets`.
Restricted field evolution uses the existing encrypted column and requires no credential migration.

Deploy the additive schema before application code. Application rollback does not alter encrypted
records. Schema rollback removes ordinary instruction columns only while all remain null; once any
instruction exists, rollback raises and leaves columns and data in place. The #255 table rollback still
refuses removal after any relationship or encrypted record exists.

## Staging and mobile verification

Before accepting restricted data:

1. Confirm the additive migration and encryption configuration load without printing key material.
2. Verify Managed Service and Self Managed Admin, Captain, Owner, read-only, inactive, revoked,
   lifecycle, and mixed-Account decisions with synthetic values.
3. Verify initial HTML and hidden inputs contain no plaintext; reveal returns only one selected value
   with no-store headers; hide and Turbo navigation/back remove revealed text.
4. Verify Keep Existing, Replace, Clear, validation failure, partial update, and concurrent update
   behavior without exposing old values.
5. Verify ordinary instructions follow normal Vessel authorization, render untrusted input as escaped
   text, and remain absent from search and unrelated previews.
6. Verify protected reassignment/deletion still preserve the Vessel, encrypted record, Documents,
   Engines, and Batteries; verify unprotected workflows still succeed.
7. Verify audit and Rails logs contain field names and safe identifiers only.
8. At a mobile viewport, verify masked state, deliberate one-field reveal, explicit hide, blank
   replacement inputs, touch-sized controls, multiline text, and usable wrapping.
9. Verify backup/restore and key-custody procedures retain required encryption material.

## MVP limitations and collection gate

The MVP does not provide external credential sharing, invitation management, Captain assignment,
per-field ACLs, attachments, rich text, automated rotation, credential export, version history,
cross-Account transfer, or a general retention/offboarding workflow.

Implementation and deployment alone do not authorize real credential collection. Keep collection
limited to synthetic values until the owner approves staging security/regression results, production
deployment and smoke tests, encryption-key custody and restore compatibility, Captain-access operating
conditions under #156, reveal/authorization behavior, and remaining privacy/retention implications.
