/**
 * supabase-fhir behind Elysia (Bun). The caller's Supabase JWT is forwarded to the database,
 * so row level security runs as the end user and this API never needs the service role key.
 *
 *   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... bun run examples/elysia/src/index.ts
 *   curl http://127.0.0.1:3000/patients -H "Authorization: Bearer <user jwt>"
 */
import { createClient } from '@supabase/supabase-js';
import { Elysia, t } from 'elysia';
import { createFhirClient, FhirError, type Database } from '../../../packages/typescript/src';

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

class AuthError extends Error {}

function outcome(code: string, diagnostics: string) {
  return { resourceType: 'OperationOutcome', issue: [{ severity: 'error', code, diagnostics }] };
}

/** A FHIR client bound to the caller's JWT: the database decides what this user may see. */
function fhirFor(authorization: string | undefined) {
  if (!authorization?.startsWith('Bearer ')) throw new AuthError('Bearer token required');
  const supabase = createClient<Database>(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return createFhirClient(supabase);
}

const app = new Elysia()
  .onError(({ error, set }) => {
    if (error instanceof AuthError) {
      set.status = 401;
      return outcome('login', error.message);
    }
    if (error instanceof FhirError) {
      set.status = error.status;
      return error.outcome ?? outcome('exception', error.message);
    }
  })
  .derive(({ headers }) => ({ fhir: fhirFor(headers.authorization) }))
  .get('/patients', ({ fhir }) => fhir.search('Patient', { limit: 50 }))
  .get('/patients/:id', ({ fhir, params }) => fhir.read('Patient', params.id))
  .get('/patients/:id/everything', ({ fhir, params }) => fhir.everything(params.id))
  .get(
    '/patients/:id/observations',
    ({ fhir, params, query }) => {
      const where: Record<string, string> = {};
      if (query.code) where.code = query.code;
      if (query.category) where.category_code = query.category;
      return fhir.search('Observation', { patientId: params.id, where, limit: 100 });
    },
    { query: t.Object({ code: t.Optional(t.String()), category: t.Optional(t.String()) }) },
  )
  .listen(Number(process.env.PORT ?? 3000));

console.log(`supabase-fhir Elysia example listening on http://127.0.0.1:${app.server?.port}`);
