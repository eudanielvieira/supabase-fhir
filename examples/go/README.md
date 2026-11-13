# Go example

Standard library only. Start the local stack (`bun run db:start` at the repository root), then:

```bash
cd examples/go
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> go run .
```

What it shows: password login, listing the patients the user may see, an audited read through
`read_resource`, a search on generated columns and a 404 carrying a FHIR OperationOutcome.
For typed resources use a FHIR model library such as `github.com/samply/golang-fhir-models`
and unmarshal the `resource` field into it. The full HTTP contract is in `docs/api.md`.
