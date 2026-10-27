# Boat Binder Agent Operating Boundaries

## Project priorities

Boat Binder is a Rails SaaS for boat owners and marine professionals. It stores personal and
vessel-related information. Treat security, customer privacy, account and data isolation,
maintainability, architectural restraint, backward compatibility, and operational safety as
first-class priorities.

## Working principles

- Inspect the existing implementation and every affected path before changing code.
- Reuse established patterns instead of creating parallel services, helpers, abstractions,
  configuration, or sources of truth.
- Prefer the smallest coherent change that fully solves the approved problem.
- Preserve existing behavior, customer data, URLs, integrations, billing state, authentication
  behavior, authorization boundaries, and operational workflows unless a change is explicitly
  approved.
- Consider affected roles, data states, account isolation, migrations, deployment order, rollback,
  and regression coverage.
- Keep pull requests focused. Remove superseded code and tests when it is safe to do so rather than
  leaving competing implementations.

If implementation complexity or scope grows materially beyond the approved plan, stop and report
the tradeoff before continuing. Do not silently turn a narrow fix into a new subsystem.

## Security and privacy

Preserve secure-by-default behavior, least privilege, strong account and data isolation,
server-side authorization, safe upload and file handling, responsible secret management, data
minimization, and the existing security and dependency controls.

Do not weaken authentication, authorization, upload, storage, billing, account-isolation, or
customer-data boundaries to simplify implementation or testing. Never publish credentials, tokens,
secrets, private keys, customer records, sensitive vessel information, or unnecessary production
operational information.

This repository is intentionally public. Treat all repository content and GitHub discussion as
publicly readable.

## Deployment boundary

The authoritative shared-staging workflow is:

1. Work on a feature branch.
2. Run appropriate local tests and static analysis.
3. Push the branch and open or update a pull request.
4. Allow required GitHub CI to complete.
5. Obtain human review and approval and resolve review conversations.
6. Merge the pull request into `main`.
7. Allow the existing Heroku GitHub integration to deploy `main` automatically to the shared
   staging app after required checks.
8. Have the human owner perform staging acceptance testing.
9. Treat production deployment as a separate, explicitly human-approved action.

**The shared staging environment represents `main`.**

Do not directly deploy feature branches, pull-request commits, or arbitrary SHAs to the shared
Heroku staging app. Do not run direct Heroku deployment commands, manually deploy a branch through
Heroku, promote releases, deploy production, restart or scale processes, configure or otherwise
mutate a Heroku app, or change Heroku config vars, add-ons, domains, process formation, or
credentials unless the human owner explicitly authorizes that exact operation in the current
conversation.

Authorization to implement, test, commit, push, open or update a pull request, inspect a pull
request, or QA code does not imply deployment authority. A request to test, verify, QA, or check
staging behavior does not authorize deploying a pull-request branch to shared staging.

If staging verification is needed before merge, provide the human owner with a concise manual test
checklist. Pull-request-specific deployments may use Review Apps only if a separate Review App
workflow is later implemented and approved. Until then, shared staging remains `main` only.

## Human staging acceptance

Customer-facing staging verification should generally be performed by the human owner after
implementation and CI. Provide a concise staging test plan, expected behavior, and the meaningful
regressions and security boundaries to verify. Do not repeatedly deploy intermediate commits to
staging to iterate on UI behavior.

## Agent usage and cost restraint

Agentic usage is limited and should be used intentionally. When practical, handle reasoning,
architecture, issue planning, and pull-request review decisions outside the coding agent. Routine
implementation, tests, UI changes, and focused bug fixes should normally use Medium reasoning.
Reserve stronger reasoning for security-sensitive architecture, authorization, migrations,
difficult debugging, or high-risk operational work.

Avoid repeated full-repository investigations when affected paths are already known, repeated
broad self-review loops after small changes, repeated staging deployments, duplication of expensive
verification already covered by CI without a concrete reason, and unrelated autonomous exploration.

## Testing

Use focused coverage plus proportionate regression coverage. Repository-standard checks, as
applicable, are:

- Rails tests;
- system tests;
- RuboCop;
- Brakeman;
- Bundler Audit;
- importmap audit;
- Zeitwerk;
- GitHub CI.

Do not substitute staging experimentation for deterministic automated tests when the behavior can
reasonably be covered automatically.

## Production access

Production inspection or mutation requires explicit human authorization. Use the minimum necessary
access. Prefer health and status checks, pass/fail verification, sanitized counts only when needed,
and staging-safe reproduction. Avoid retrieving customer records merely to prove behavior. Sanitize
any evidence intended for GitHub because this repository is public.

## GitHub workflow

Preserve the pull-request-based default-branch workflow, required CI, no standing bypass, resolved
review conversations, human review of agent-authored changes, immutable GitHub Actions references,
Dependabot, Brakeman, Bundler Audit, importmap audit, CodeQL, GitHub secret scanning and push
protection, least-privilege Actions permissions, and the existing ruleset as the enforcement source
of truth.

Do not introduce duplicate scanners, dependency bots, protection systems, or CI enforcement without
a concrete gap.

## Pull-request completion

Before declaring a pull request ready, report:

- what changed;
- which existing paths were reused;
- security, privacy, and authorization implications;
- compatibility considerations;
- relevant test results;
- cleanup performed;
- migration and deployment considerations;
- remaining manual verification scenarios.

Do not merge automatically unless explicitly requested. Do not deploy production as part of ordinary
pull-request completion.
