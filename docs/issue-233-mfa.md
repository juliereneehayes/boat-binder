# Issue #233: TOTP MFA rollout and operations

## Architecture

MFA is one `User`-scoped credential for Admins, Captains, and voluntarily enrolled Owners. Password authentication remains authoritative and runs before MFA. When MFA applies, the password step creates no `Session`; it creates a separate Rails encrypted cookie containing only a User ID, a random challenge nonce, a keyed credential-state digest, and a ten-minute expiry. Normal authentication continues to recognize only the signed `session_id` cookie.

The MFA challenge is single-use through a privacy-preserving nonce key in the application cache. A successful TOTP, recovery-code, or enrollment confirmation consumes that challenge before `Authentication#start_new_session_for` creates the existing authoritative `Session`. Role, active-state, or password changes invalidate an outstanding challenge through its keyed credential-state digest.

`PRIVILEGED_MFA_ENFORCEMENT` is the single rollout control. It defaults to false. Enrolled users always use MFA, regardless of role or rollout state. A User with an in-progress enrollment or re-enrollment must finish it before receiving another Session. When the control is true, every unenrolled Admin or Captain receives only the restricted enrollment challenge after password authentication.

## Schema and secret storage

The additive User migration adds:

- `mfa_totp_secret`: non-deterministically encrypted by Rails Active Record Encryption;
- `mfa_enrolled_at`: explicit activation state;
- `mfa_last_accepted_timestep`: replay protection for accepted TOTP timesteps;
- `mfa_recovery_code_digests`: PostgreSQL text array containing bcrypt hashes only.

Encryption material is purpose-derived from the application's existing `secret_key_base` with Rails' key generator. It is never committed or hardcoded. Treat `secret_key_base` as credential-encryption key material after this deployment: retain the old derived key during any future key rotation until all MFA ciphertext has been re-encrypted.

Enrollment uses a 32-character cryptographically random Base32 secret, six digits, a 30-second period, and at most one timestep of clock skew. Activation requires a valid code. QR codes are rendered locally; provisioning URIs are never sent to a third party. The manual secret and QR are reachable only while enrollment is pending.

Exactly ten 128-bit recovery codes are generated. Plaintext is rendered only in the response that creates or regenerates them. Normalized values are bcrypt-hashed before persistence. Consumption holds the User row lock, removes one matching hash, and commits with Session creation and the audit event. Regeneration atomically replaces the complete digest array.

## Rate limits, audit, and authorization

MFA verification permits five attempts per ten minutes per challenged User identity and adds a 20-attempt per ten-minute source-IP ceiling. Both use the existing Rails cache rate-limit mechanism; the challenged-User key is a purpose-separated HMAC rather than a raw identifier or token. Tests inject an isolated memory store through the same isolated-execution-state pattern as sign-in and email-change throttles.

The authoritative `SecurityAudit::Recorder` records these global User events:

- `authentication.mfa_enrolled`;
- `authentication.mfa_recovery_code_used`;
- `authentication.mfa_recovery_codes_regenerated`;
- `authentication.mfa_reenrollment_started`.

They contain IDs and request metadata only—never secrets, codes, hashes, challenge data, or copied user attributes. All Settings actions derive authority from `Current.user`; restricted enrollment derives it only from the encrypted challenge. Submitted IDs are ignored. MFA never changes memberships or Account authorization.

## Activation sequence

1. Deploy the additive migration while `PRIVILEGED_MFA_ENFORCEMENT` is absent or false.
2. Deploy the capability code with the same setting. Existing unenrolled Admins and Captains continue their current password-to-Session flow; any enrolled user uses MFA immediately.
3. Validate dedicated Owner, Admin, and Captain identities in staging using the checklist below.
4. Validate recovery-code sign-in and re-enrollment for a staging Admin.
5. Deploy the same capability to production with enforcement still false.
6. Enroll at least one production Admin and verify that Admin's TOTP and recovery-code paths.
7. Set `PRIVILEGED_MFA_ENFORCEMENT=true` and restart all application processes together.
8. Confirm unenrolled Admin/Captain password authentication reaches only enrollment and creates no Session.
9. After privileged enrollment is complete and the rollout is stable, remove the temporary environment control in a focused cleanup change by making privileged enforcement unconditional. Do not introduce a replacement flag.

## Rollback

Prefer a forward fix. To suspend mandatory privileged enforcement without discarding credentials, set `PRIVILEGED_MFA_ENFORCEMENT=false` and restart all processes. Enrolled users still require MFA; unenrolled privileged users regain the pre-enforcement password flow. This is the intended emergency application rollback.

Do not reverse the migration or clear MFA columns merely to roll back application code. The schema is additive, and the encrypted secret plus recovery hashes must be retained. If older application code must temporarily run, keep the columns in place; it ignores them. Never rotate or discard `secret_key_base` as part of an MFA rollback.

If an enrolled privileged user loses both authenticator and recovery codes, use a production console with a narrowly selected numeric User ID:

```ruby
user = User.find(123)
raise "privileged user required" unless user.internal?
Mfa::Reset.call!(user: user)
```

This is not a bypass: it revokes every Session, creates a new pending enrollment, and records `authentication.mfa_reenrollment_started`. The user must still pass their password and complete new MFA enrollment. Record the operator/ticket context outside the application event because this non-web procedure has no authenticated application actor.

## Manual staging checklist

1. Confirm an unenrolled Owner signs in directly with the unchanged Session lifetime and cookie behavior.
2. Enroll an Owner by scanning the locally rendered QR code.
3. Enroll another Owner with the manual secret.
4. Confirm the enrolled Owner's next sign-in requires TOTP.
5. Sign in with one recovery code and save the remaining count.
6. Confirm the consumed recovery code is rejected.
7. Regenerate recovery codes and confirm every prior unused code is rejected.
8. Enroll an Admin while enforcement is false, then verify TOTP and recovery sign-in.
9. Enroll a Captain through the restricted flow after staging enforcement is true.
10. Confirm an unenrolled privileged identity can reach enrollment/sign-out but no application page and has no Session row.
11. On iOS and Android, verify the numeric keypad, paste, and one-time-code autofill behavior.
12. Confirm wrong TOTP and recovery values receive the same generic verification failure.
13. Confirm the sixth attempt inside ten minutes receives the generic throttle response and source-IP protection remains active.
14. Change Owner to Captain/Admin, confirm existing Sessions are revoked, and confirm the next login requires enrollment/MFA.
15. Change Captain/Admin to Owner, confirm Sessions are revoked, and confirm existing MFA enrollment remains required for that enrolled Owner.
16. Reset/re-enroll MFA, confirm every Session is revoked, old TOTP/recovery codes fail, and the restricted enrollment succeeds.
17. Inspect only action/outcome/actor/target/request metadata in the four MFA audit event types; confirm no credential material.
18. Confirm crafted User/Account IDs cannot read or change another User's MFA and Owner memberships are unchanged.
19. Recheck idle/absolute Session expiry, Active Sessions, sign-out, and Action Cable authentication.

## Explicit non-goals

This change does not add trusted devices, mandatory Owner MFA, optional disable, passkeys, SMS/email OTP, an identity provider, a second Session system, persistent pre-auth records, broad Admin reset UI, or an MFA bypass. Optional Owner disable and database-level audit tamper resistance remain separate work.
