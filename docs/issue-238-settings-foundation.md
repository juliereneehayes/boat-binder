# Issue #238 deployment and staging notes

## Schema and deployment

The migration adds two nullable `users` columns: `pending_email_address` and
`email_change_requested_at`. A check constraint requires the two fields to be
present or null together. Pending addresses do not reserve a login address;
authoritative uniqueness remains enforced on `users.email_address` when a change
is confirmed. No existing user, account, membership, billing, or session data is
rewritten or deleted.

Apply the additive migration before new application code begins serving traffic.
During a rolling deploy, old code may safely continue serving with both nullable
columns present. Start new application processes and route traffic to them only
after migration `20260928010000` has completed successfully. The new application
keeps `users.email_address` authoritative until a pending address is verified.

Prefer a forward fix if authentication behavior needs correction after deployment.
If the application is rolled back while the columns remain, pending requests are
inert because old code neither reads nor confirms them. A later forward deploy can
resume them until their 24-hour signed tokens expire. Before rolling back the
migration, first restore or drain every new-code process. Removing the columns then
discards only pending email-change state; authoritative email addresses and all
existing customer/account data remain unchanged.

## Pre-launch follow-up

Track a separate focused change to notify the previous email address after a
verified login-email change. Recovery and reversal tooling remain out of scope for
this PR.

## Manual staging plan

1. Sign in as an Owner, open Settings, and update the user's name.
2. Sign in as an Admin and a Captain and confirm each sees the same Settings experience for their own account.
3. Confirm primary navigation shows Settings and no standalone Active Sessions destination.
4. Sign in to one user in two browsers and confirm both appear under Settings > Security.
5. Select **Sign out other sessions** and confirm the current browser remains signed in.
6. Request an email change with the correct current password.
7. Confirm the old email remains authoritative before verification.
8. Confirm the verification message arrives only at the requested new address.
9. Follow the verification link and complete the change.
10. Confirm all existing sessions are revoked and the verifying browser returns to sign-in.
11. Confirm the old email no longer signs in.
12. Confirm the new email signs in.
13. Confirm malformed, expired, replayed, and superseded links fail with the same generic recovery.
14. Confirm feature-specific logging contains no submitted passwords, verification tokens, or submitted/current/pending email addresses. Confirm Settings exposes no raw session IDs or session IP metadata. Request IPs may remain in standard infrastructure logs, and justified operational errors may contain internal user IDs without direct PII or tokens.
