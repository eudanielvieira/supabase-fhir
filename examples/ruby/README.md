# Ruby example

Standard library only (`net/http`, `json`). Start the local stack (`bun run db:start` at the
repository root), then:

```bash
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> ruby examples/ruby/example.rb
```

What it shows: password login, listing the patients the user may see, an audited read through
`read_resource`, a search on generated columns and a 404 carrying a FHIR OperationOutcome.
In Rails the `Client` becomes a service object; for typed resources use the `fhir_models` gem.
The full HTTP contract is in `docs/api.md`.
