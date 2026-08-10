# Production Email

Boat Binder sends transactional email through SMTP in production. Mailgun SMTP is configured through Heroku config vars.

Current transactional email includes:

- Password resets
- Account invitations
- Service visit summaries

Do not commit SMTP credentials or add `.env`/dotenv support. Set values through Heroku config vars, for example:

```sh
heroku config:set SMTP_ADDRESS=smtp.mailgun.org SMTP_PORT=587 SMTP_DOMAIN=mg.example.com MAIL_FROM=no-reply@example.com APP_HOST=app.boat-binder.com --app boat-binder
heroku config:set SMTP_USERNAME=postmaster@mg.example.com SMTP_PASSWORD=... --app boat-binder
```

Password reset delivery failures are logged server-side and shown to users as a generic safe message to avoid account enumeration.
