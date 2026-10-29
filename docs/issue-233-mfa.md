# Issue #233: TOTP MFA rollout and operations

## Architecture

MFA is one `User`-scoped credential for Admins, Captains, and voluntarily enrolled Owners. Password authentication remains authoritative and runs before MFA. When MFA applies, the password step creates no `Session`; it creates a separate Rails encrypted cookie containing only a User ID, a random challenge nonce, a keyed credential-state digest, and a ten-minute expiry. Normal authentication continues to recognize only the signed `session_id` cookie.

The MFA challenge is single-use through a privacy-preserving nonce key in the application cache. Every password, invitation-acceptance, or email-verification entry point uses the same post-primary-authentication gate to either create the existing authoritative `Session` or issue an MFA challenge. A successful TOTP, recovery-code, or enrollment confirmation consumes that challenge before the low-level `Authentication#start_new_session_for` method creates the Session. Role, active-state, password, enrollment state, or encrypted MFA credential changes invalidate an outstanding challenge through its keyed credential-state digest. A copied challenge from before reset therefore cannot reveal or confirm the replacement credential. Self-service email verification remains Owner-only because `SelfServiceRegistration.pending_verification?` authoritatively rejects internal roles before activation.

MFA is mandatory for every Admin and Captain. After password authentication, an unenrolled privileged user receives only the restricted enrollment challenge and cannot establish a normal Session until enrollment succeeds. An Owner's first-time pending setup remains required until the Owner completes or explicitly cancels it. Once reset/re-enrollment starts, the old TOTP credential is immediately invalidated and the durable re-enrollment marker prevents cancellation into an MFA-disabled state for every role.

## Schema and secret storage

The additive User migrations add:

- `mfa_totp_secret`: non-deterministically encrypted by Rails Active Record Encryption;
- `mfa_enrolled_at`: explicit activation state;
- `mfa_reenrollment_started_at`: distinguishes required reset/re-enrollment from cancellable first-time Owner setup;
- `mfa_last_accepted_timestep`: replay protection for accepted TOTP timesteps;
- `mfa_recovery_code_digests`: PostgreSQL text array containing bcrypt hashes only.

Production and staging use dedicated environment-backed Rails Active Record Encryption material, independent of `secret_key_base`:

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`: current encryption key material;
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`: stable environment-specific derivation salt;
- `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEYS`: optional comma-separated previous keys, oldest to newest, used only for rotation.

The first two variables must contain at least 32 bytes and must be configured before deploying this code or running the release migration. Every process or build that boots with `RAILS_ENV=production`, including production-mode asset build/precompile environments, fails when either value is absent or too short. Generate unique values for staging and production; do not reuse `SECRET_KEY_BASE`. Local development/test use purpose-derived local material only when dedicated values are absent. Rails stores key references in new ciphertext, uses the last configured primary key for encryption, and can decrypt with the temporary previous-key list.

Enrollment uses a 32-character cryptographically random Base32 secret, six digits, a 30-second period, and at most one timestep of clock skew. Activation requires a valid code. QR codes are rendered locally; provisioning URIs are never sent to a third party. The manual secret and QR are reachable only while enrollment is pending.

Exactly ten 128-bit recovery codes are generated. Plaintext is rendered only in the response that creates or regenerates them. Normalized values are bcrypt-hashed before persistence. Consumption holds the User row lock, removes one matching hash, and commits with Session creation and the audit event. Regeneration atomically replaces the complete digest array.

## Rate limits, audit, and authorization

MFA verification permits five attempts per ten minutes per challenged User identity and adds a 20-attempt per ten-minute source-IP ceiling. Recovery-code regeneration and reset/re-enrollment password prompts each permit five attempts per 15 minutes per authenticated User. These controls use the existing Rails cache rate-limit mechanism and purpose-separated HMAC User identifiers. Tests inject isolated memory stores through the same isolated-execution-state pattern as sign-in and email-change throttles.

Production depends on the configured shared Solid Cache store for challenge-consumption markers and all MFA throttles. Do not run production MFA with `NullStore`, an in-process memory store, or another per-process-only cache.

The authoritative `SecurityAudit::Recorder` records these global User events:

- `authentication.mfa_enrolled`;
- `authentication.mfa_recovery_code_used`;
- `authentication.mfa_recovery_codes_regenerated`;
- `authentication.mfa_reenrollment_started`.

They contain IDs and the request ID only—never a persisted source IP, secrets, codes, hashes, challenge data, or copied user attributes. Source IP remains ephemeral input to Rails' abuse throttle. All Settings actions derive authority from `Current.user`; restricted enrollment derives it only from the encrypted challenge. Submitted IDs are ignored. MFA never changes memberships or Account authorization. Responses containing a pending QR/manual secret or newly generated recovery plaintext send `Cache-Control: no-store`.

## Encryption-key rotation

Keep `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` stable during primary-key rotation. Rotate without mixed-version write failures in three phases:

1. Generate a new independent primary key. Keep the old key current, append the new key to `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEYS`, and restart every process. All processes still write the old key, while the fully restarted fleet can read both.
2. Make the new key `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, move the old key into `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEYS` (along with any still-needed older keys), and restart every process. Both phase-one and phase-two processes can read both keys during this rolling change; only phase-two processes write the new key.
3. Re-encrypt every non-null MFA secret under the new current key:

   ```sh
   bin/rails runner 'User.where.not(mfa_totp_secret: nil).find_each { |user| user.update_columns(mfa_totp_secret: user.mfa_totp_secret) }'
   ```

   Then run a one-off verification process with the new current key and same salt but no previous keys:

   ```sh
   ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEYS= bin/rails runner 'User.where.not(mfa_totp_secret: nil).find_each { |user| user.mfa_totp_secret }; puts "all MFA secrets decrypted with the current key"'
   ```

   The process exits nonzero on any decryption error. Only after it succeeds may the old key be removed from the previous-key variable and every process restarted. If verification fails, retain the old key, correct/re-run re-encryption, and do not clear credentials.

This uses Rails' supported multi-key provider and does not require wiping MFA credentials. Changing the derivation salt requires a separate controlled migration that configures the old scheme explicitly; do not change it as part of an ordinary primary-key rotation.

## Deployment and rollback

Privileged MFA enforcement is part of the application policy and has no runtime bypass. Deploy through the normal pull-request workflow after focused and full authentication regression coverage passes. This cleanup has no migration and must not modify existing MFA credentials, recovery-code digests, Sessions, or encryption configuration.

After deployment, verify with dedicated non-customer identities that an unenrolled Admin or Captain receives restricted enrollment without a normal Session, enrolled privileged TOTP and recovery-code sign-in succeed, and an unenrolled Owner still signs in normally. Inspect only privacy-minimized audit metadata and sanitized application health/error results.

Prefer a forward fix for defects. If rollback is necessary, revert and deploy the prior known-good application release; do not add another runtime bypass. A previous release may still contain the disabled-state compatibility path, so keep its existing `PRIVILEGED_MFA_ENFORCEMENT=true` configuration enabled through rollback and verify that an unenrolled Admin or Captain still cannot establish a normal Session. Keep the additive MFA columns and all encrypted credentials and recovery-code digests intact. Retain the configured Active Record Encryption key and salt through rollback so the prior release can continue reading existing MFA secrets.

Do not remove the production `PRIVILEGED_MFA_ENFORCEMENT` config variable as part of this code cleanup. The unconditional policy safely ignores it. Retire the variable only after this release has deployed successfully, privileged MFA has passed post-deployment verification, the rollback stabilization window has closed, and flag-dependent releases are no longer eligible rollback targets.

If any enrolled active user, including an Owner, loses both authenticator and recovery codes, first complete out-of-band identity verification and create a support/ticket record identifying the operator and reason. Then use a production console with a narrowly selected numeric User ID:

```ruby
user = User.find(123)
raise "active enrolled user required" unless user.active? && user.mfa_enrolled?
Mfa::Reset.call!(user: user)
```

This is not a bypass: it immediately invalidates the old TOTP credential and every recovery code, revokes every Session, creates a durably marked mandatory pending re-enrollment, and records the authoritative `authentication.mfa_reenrollment_started` event. Re-enrollment cannot be cancelled into an MFA-disabled state; the user must pass their password and complete the replacement enrollment before a new Session is created. Keep the operator, out-of-band verification, ticket, and reason in the support record because this non-web procedure has no authenticated application actor.

## Manual staging checklist

1. Confirm an unenrolled Owner signs in directly with the unchanged Session lifetime and cookie behavior.
2. Enroll an Owner by scanning the locally rendered QR code.
3. Enroll another Owner with the manual secret.
4. Start and cancel an Owner's first-time unconfirmed enrollment, then confirm password sign-in remains direct; start re-enrollment for an enrolled Owner and confirm cancellation is denied with no normal Session.
5. Confirm the enrolled Owner's next sign-in requires TOTP.
6. Sign in with one recovery code and save the remaining count.
7. Confirm the consumed recovery code is rejected.
8. Regenerate recovery codes and confirm every prior unused code is rejected.
9. Enroll an Admin through the restricted flow, then verify TOTP and recovery sign-in.
10. Enroll a Captain through the restricted flow.
11. Confirm an unenrolled privileged identity can reach enrollment/sign-out but no application page and has no Session row.
12. On iOS and Android, verify the numeric keypad, paste, and one-time-code autofill behavior.
13. Confirm wrong TOTP and recovery values receive the same generic verification failure.
14. Confirm the sixth MFA attempt inside ten minutes and sixth Settings password attempt inside 15 minutes receive the generic throttle response.
15. Change Owner to Captain/Admin, confirm existing Sessions are revoked, and confirm the next login requires enrollment/MFA.
16. Change Captain/Admin to Owner, confirm Sessions are revoked, and confirm existing MFA enrollment remains required for that enrolled Owner.
17. Using staging's actual shared Solid Cache store, establish and successfully complete an MFA challenge, restore the consumed challenge cookie, replay it, and confirm it is rejected without creating another Session.
18. Separately reset/re-enroll MFA, restore a copied pre-reset challenge, and confirm it cannot reveal the new secret or create a Session.
19. Inspect only action/outcome/actor/target/request metadata in the four MFA audit event types; confirm `source_ip` and credential material are absent.
20. Confirm crafted User/Account IDs cannot read or change another User's MFA and Owner memberships are unchanged.
21. Recheck idle/absolute Session expiry, Active Sessions, sign-out, and Action Cable authentication.

## Explicit non-goals

This change does not add trusted devices, mandatory Owner MFA, disabling active Owner MFA, passkeys, SMS/email OTP, an identity provider, a second Session system, persistent pre-auth records, broad Admin reset UI, or an MFA bypass. Only cancellation of an unconfirmed first-time Owner setup is included. Optional disable of active Owner MFA and database-level audit tamper resistance remain separate work.
