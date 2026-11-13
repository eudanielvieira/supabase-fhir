# Java example

Java 17+ with the JDK `HttpClient` and Jackson for JSON (the only dependency). Start the local
stack (`bun run db:start` at the repository root), then:

```bash
cd examples/java
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> mvn -q compile exec:java
```

What it shows: password login, listing the patients the user may see, an audited read through
`read_resource`, a search on generated columns and a 404 carrying a FHIR OperationOutcome.
In Spring Boot the `Client` class becomes a bean built from `RestClient` or `WebClient`; for
typed resources parse the `resource` field with HAPI FHIR structures (`org.hl7.fhir.r4.model`).
The full HTTP contract is in `docs/api.md`.
