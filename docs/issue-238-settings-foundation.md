# Issue #238 deployment and staging notes

## Schema and deployment

The migration adds two nullable `users` columns: `pending_email_address` and
`email_change_requested_at`. A partial unique index protects non-null pending
addresses, and a check constraint requires the two fields to be present or null
together. No existing user, account, membership, billing, or session data is
rewritten or deleted.

Deploy the additive migration before or with the application code. The previous
application version safely ignores both nullable columns, so it remains compatible
during a rolling deploy. The new application keeps `users.email_address`
authoritative until a pending address is verified.

Prefer a forward fix if authentication behavior needs correction after deployment.
If the application is rolled back while the columns remain, pending requests are
inert because old code neither reads nor confirms them. A later forward deploy can
resume them until their 24-hour signed tokens expire. If the migration itself must
be rolled back, pending email-change state is discarded when the two new columns
are removed; authoritative email addresses and all existing customer/account data
remain unchanged.

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
14. Confirm the UI and logs expose no user IDs, session IDs, IP addresses, passwords, or verification tokens.
