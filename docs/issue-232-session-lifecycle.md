# Issue #232 deployment and staging notes

## Deployment and rollback

Deploy the additive schema migration before or with the application code. Both lifecycle columns are nullable so the previous application version can continue creating sessions during a rolling deployment. Once the new code is running, any session with a null lifecycle value is intentionally invalid and the user must sign in again. The migration does not delete customer or account data.

Prefer a forward fix after deployment. Rolling back only the application code would make the old permanent-cookie behavior authoritative again and could restore indefinite sessions. If application rollback is unavoidable, keep the additive columns in place; remove them only after the old application is no longer writing sessions and the security implications have been reviewed.

Already-established Action Cable connections are not force-disconnected when their session is later revoked. New connections always revalidate the server-side session and are rejected after revocation or expiry.

## Manual staging plan

1. Sign in and sign out normally as an Owner.
2. Sign in and sign out normally as an Admin and a Captain.
3. Sign in to the same user in two browsers and confirm both appear under Active Sessions.
4. Confirm Active Sessions contains only the current user's sessions and exposes no session IDs or IP addresses.
5. Sign out other sessions and confirm the current browser remains signed in while the other browser must reauthenticate.
6. Reset a password and confirm all prior sessions require reauthentication.
7. Deactivate a user as an Admin and confirm all of that user's sessions are revoked.
8. Change a user's role as an Admin and confirm all of that user's sessions are revoked.
9. Set `last_seen_at` beyond the role's idle limit and confirm the next request requires reauthentication.
10. Set `expires_at` to the present or past and confirm the next request requires reauthentication.
11. Confirm Owner sessions receive a 30-day absolute expiry and Admin/Captain sessions receive a 7-day expiry.
12. Create a session with null lifecycle columns and confirm its cookie requires reauthentication.
13. Open an Action Cable connection with a valid session, then confirm new connections are rejected after expiry or revocation.
