# C# example

.NET 8+, `HttpClient` and `System.Text.Json` only. Start the local stack (`bun run db:start`
at the repository root), then:

```bash
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> dotnet run --project examples/csharp
```

What it shows: password login, listing the patients the user may see, an audited read through
`read_resource`, a search on generated columns and a 404 carrying a FHIR OperationOutcome.
In ASP.NET Core register `FhirClient` through `IHttpClientFactory`; for typed resources parse
the `resource` field with the Firely .NET SDK (`Hl7.Fhir.R4`). The full HTTP contract is in
`docs/api.md`.
