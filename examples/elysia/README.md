# Elysia example

The same idea as the NestJS example, on Bun with Elysia: forward the caller's Supabase JWT and
let row level security run as the end user. No service role key in the API.

```bash
bun install                                   # at the repository root (workspaces)
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<anon key> bun run example:elysia
curl http://127.0.0.1:3000/patients -H "Authorization: Bearer <user jwt>"
```

Routes: `GET /patients`, `GET /patients/:id` (audited), `GET /patients/:id/everything`,
`GET /patients/:id/observations?code=&category=`. `onError` maps `FhirError` to the status and
OperationOutcome the database produced. In a larger app keep `createFhirClient()` as the
infrastructure adapter behind your use cases.
