# Contributing

Thanks for helping. A few ground rules keep this project safe to use in healthcare settings.

## Before you open a pull request

```bash
bun install
bun run typecheck      # TypeScript
bun test               # unit tests
bun run db:start       # local Supabase with migrations and seeds (needs Docker)
bun run test:db        # pgTAP tests against the local database
```

All four must pass. CI runs the same commands.

## Rules

- **Never weaken a policy without a test.** Every change to RLS, grants or the audit triggers
  needs a pgTAP test in `supabase/tests/` that proves the new behaviour and the old guarantees.
- **New resource types go in two places:** `select fhir.define_resource('Type')` in a migration,
  and `TABLE_NAMES` plus `ResourceMap` in `src/domain/resource-types.ts`.
- **Migrations are append only.** Add a new `supabase/migrations/<timestamp>_<name>.sql`; do not
  edit a migration that was already published.
- **Synthetic data only.** Seeds and fixtures come from Synthea or are hand written. No real
  patient data, ever, not even anonymised.
- **No emojis** in code, docs or commits.
- **Conventional Commits**: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:` with an optional
  scope, for example `feat(rls): time-boxed access grants`.

## Reporting security issues

Open a private security advisory on GitHub instead of a public issue.
