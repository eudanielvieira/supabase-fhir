# PHP example

PHP 8.1+, no dependencies (streams only, `ext-curl` is not needed). Start the local stack
(`bun run db:start` at the repository root), then:

```bash
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> php examples/php/example.php
```

What it shows: password login, listing the patients the user may see, an audited read through
`read_resource`, a search on generated columns and a 404 carrying a FHIR OperationOutcome.
For typed resources use a FHIR model library such as `dcarbone/php-fhir` and hydrate the
`resource` field with it. In Laravel or Symfony, the same calls fit in an HTTP client service.
The full HTTP contract is in `docs/api.md`.
