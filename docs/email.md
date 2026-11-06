# Production Email

Boat Binder sends transactional email through SMTP in production. Mailgun SMTP is configured through Heroku config vars.

Current transactional email includes:

- Password resets
- Account invitations
- Service visit summaries
- Sanitized operational health alerts to the configured operator recipient

## Service Visit summary recipients

PR [#260](https://github.com/juliereneehayes/boat-binder/pull/260) previously limited Service Visit
summary delivery to an authenticated, verified Owner User. Phase 1 of issue #258 intentionally
changes that rule for Admin- and Captain-created visits: the summary is sent to the Account's
operator-maintained primary Owner Contact email even when that Contact has no authenticated or
verified Owner User.

This accepts the manual-recipient risk that an incorrect Contact address could send customer-facing
visit information to the wrong mailbox. HYC operators must verify the primary Owner Contact email
during customer intake and correct it through the existing Owner workflow before creating a Service
Visit. Boat Binder continues to validate the address format, but does not add a separate Contact
verification system.

Service Visit summary, condition, follow-up, checklist, and other free-text fields included in the
email must contain only information appropriate to share with the customer. Operators must not put
restricted vessel credentials, authentication information, internal-only notes, or other sensitive
operational data in customer-facing summary fields.

The authenticated full-report link is a separate authorization decision. It is included only when
the primary Contact email matches an active, eligible Owner User with current access to that Account
and Service Visit. A linked User email is never used as a fallback delivery address.

Do not commit SMTP credentials or add `.env`/dotenv support. Set values through Heroku config vars, for example:

```sh
heroku config:set SMTP_ADDRESS=smtp.mailgun.org SMTP_PORT=587 SMTP_DOMAIN=mg.example.com MAIL_FROM=no-reply@example.com APP_HOST=app.boat-binder.com --app boat-binder
heroku config:set SMTP_USERNAME=postmaster@mg.example.com SMTP_PASSWORD=... --app boat-binder
```

Password reset delivery failures are logged server-side and shown to users as a generic safe message to avoid account enumeration.

Operational alerts use the same SMTP delivery path but are not customer mail. Their recipient is
configured separately through `OPERATIONAL_ALERT_RECIPIENT`, and delivery is performed directly by
the recurring monitor so alert contents are not serialized into another background job. See
[Operational Monitoring](operational-monitoring.md).
