# Contributing

Thanks for helping. A few ground rules keep this project safe to use in healthcare settings.

## Before you open a pull request

```bash
bun install
bun run typecheck      # TypeScript
bun test               # unit tests
bun run db:start       # local Supabase with migrations and seeds (needs Docker)
bun run test:db        # pgTAP tests against the local database
bun run test:http      # HTTP conformance through PostgREST
bun run sql:build      # regenerate sql/dist after touching a migration
```

All of them must pass. CI runs the same commands and also compiles `examples/go` and
`examples/python`, `examples/java`, `examples/csharp`, lints `examples/php` and `examples/ruby`
and typechecks `examples/nestjs` and `examples/elysia`.

## Rules

- **Never weaken a policy without a test.** Every change to RLS, grants or the audit triggers
  needs a pgTAP test in `supabase/tests/` that proves the new behaviour and the old guarantees.
- **New resource types go in three places:** `select fhir.define_resource('Type')` in a migration,
  `TABLE_NAMES` plus `ResourceMap` in `clients/typescript/src/domain/resource-types.ts`, and the
  table list in `docs/api.md`.
- **The HTTP contract is shared by every client.** A change to an RPC or an error code updates
  `docs/api.md`, `tests/http/conformance.sh`, the TypeScript client and the pgTAP tests together.
- **Migrations are append only once they ship in a tagged release.** Add a new
  `supabase/migrations/<timestamp>_<name>.sql` instead of editing one that was released, and run
  `bun run sql:build` so `sql/dist/` matches.
- **Synthetic data only.** Seeds and fixtures come from Synthea or are hand written. No real
  patient data, ever, not even anonymised.
- **No emojis** in code, docs or commits.
- **Conventional Commits**: `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:` with an optional
  scope, for example `feat(rls): time-boxed access grants`.

## Reporting security issues

Open a private security advisory on GitHub instead of a public issue.
