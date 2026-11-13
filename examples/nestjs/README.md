# NestJS example

A small API in front of supabase-fhir that forwards the caller's Supabase JWT instead of
holding the service role key. Row level security runs as the end user, so the API does not
reimplement access rules; the database is still the single source of truth.

```bash
bun install                                   # at the repository root (workspaces)
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> bun run example:nestjs
curl http://127.0.0.1:3000/patients -H "Authorization: Bearer <user jwt>"
```

| Route | Does |
|---|---|
| `GET /patients` | the patients this user may see |
| `GET /patients/:id` | audited read; 404 when invisible |
| `GET /patients/:id/everything` | Patient `$everything` Bundle |
| `GET /patients/:id/observations?code=&category=` | search on the generated columns |

Pieces: `FhirService` is request scoped and builds the client from the `Authorization` header;
`FhirExceptionFilter` maps `FhirError` to the HTTP status and OperationOutcome the database
produced; `PatientsController` only orchestrates. In a larger app the `FhirClient` is the
infrastructure adapter behind your use cases.
