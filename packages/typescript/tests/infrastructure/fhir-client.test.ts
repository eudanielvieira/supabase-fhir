import { describe, expect, test } from 'bun:test';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Observation, Patient } from 'fhir/r4';
import { createFhirClient } from '../../src/infrastructure/supabase/fhir-client';
import type { FhirDatabase } from '../../src/infrastructure/supabase/database.types';
import { FhirError } from '../../src/domain/errors';

type RpcCall = { name: string; args: Record<string, unknown> };
type QueryCall = { method: string; args: unknown[] };

interface FakeOptions {
  rpc?: (name: string, args: Record<string, unknown>) => { data: unknown; error: unknown };
  rows?: unknown[];
  queryError?: unknown;
}

function fakeSupabase(options: FakeOptions = {}) {
  const rpcCalls: RpcCall[] = [];
  const queryCalls: QueryCall[] = [];
  let table = '';

  const builder: Record<string, unknown> = {};
  for (const method of ['select', 'order', 'eq', 'match', 'limit']) {
    builder[method] = (...args: unknown[]) => {
      queryCalls.push({ method, args });
      return builder;
    };
  }
  builder.then = (resolve: (value: unknown) => void) =>
    resolve({ data: options.rows ?? [], error: options.queryError ?? null });

  const schema = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      rpcCalls.push({ name, args });
      return options.rpc?.(name, args) ?? { data: null, error: null };
    },
    from: (name: string) => {
      table = name;
      return builder;
    },
  };
  const client = { schema: () => schema } as unknown as SupabaseClient<FhirDatabase>;
  return { client, rpcCalls, queryCalls, table: () => table };
}

const patient: Patient = { resourceType: 'Patient', id: 'p1', name: [{ family: 'Doe' }] };

describe('createFhirClient', () => {
  test('read calls read_resource and returns the resource', async () => {
    const fake = fakeSupabase({ rpc: () => ({ data: patient, error: null }) });
    const fhir = createFhirClient(fake.client);

    const result = await fhir.read('Patient', 'p1');

    expect(result).toEqual(patient);
    expect(fake.rpcCalls).toEqual([{ name: 'read_resource', args: { resource_type: 'Patient', id: 'p1' } }]);
  });

  test('create and update pass the resource through', async () => {
    const fake = fakeSupabase({ rpc: (_name, args) => ({ data: args.resource, error: null }) });
    const fhir = createFhirClient(fake.client);

    await fhir.create(patient);
    await fhir.update(patient);
    await fhir.update(patient, { expectedVersion: 3 });

    expect(fake.rpcCalls[0]).toEqual({ name: 'create_resource', args: { resource: patient } });
    expect(fake.rpcCalls[1]).toEqual({ name: 'update_resource', args: { resource: patient } });
    expect(fake.rpcCalls[2]).toEqual({ name: 'update_resource', args: { resource: patient, expected_version: 3 } });
  });

  test('remove, everything and importBundle use their RPCs', async () => {
    const bundle = { resourceType: 'Bundle' as const, type: 'transaction' as const, entry: [] };
    const fake = fakeSupabase({ rpc: () => ({ data: bundle, error: null }) });
    const fhir = createFhirClient(fake.client);

    await fhir.remove('Observation', 'o1');
    await fhir.everything('p1');
    await fhir.importBundle(bundle);

    expect(fake.rpcCalls.map((c) => c.name)).toEqual(['delete_resource', 'patient_everything', 'import_bundle']);
    expect(fake.rpcCalls[1]?.args).toEqual({ patient_id: 'p1' });
    expect(fake.rpcCalls[2]?.args).toEqual({ bundle });
  });

  test('history maps rows to entries', async () => {
    const rows = [
      { version_id: 2, resource: { ...patient }, last_updated: '2024-01-02T00:00:00Z', operation: 'current' },
      { version_id: 1, resource: { ...patient }, last_updated: '2024-01-01T00:00:00Z', operation: 'update' },
    ];
    const fake = fakeSupabase({ rpc: () => ({ data: rows, error: null }) });
    const fhir = createFhirClient(fake.client);

    const history = await fhir.history('Patient', 'p1');

    expect(history.map((h) => [h.versionId, h.operation, h.lastUpdated])).toEqual([
      [2, 'current', '2024-01-02T00:00:00Z'],
      [1, 'update', '2024-01-01T00:00:00Z'],
    ]);
  });

  test('PostgREST errors become FhirError with an HTTP status', async () => {
    const fake = fakeSupabase({ rpc: () => ({ data: null, error: { code: 'PT404', message: 'Patient/x not found' } }) });
    const fhir = createFhirClient(fake.client);

    const failure = await fhir.read('Patient', 'x').catch((e: unknown) => e);

    expect(failure).toBeInstanceOf(FhirError);
    expect((failure as FhirError).status).toBe(404);
    expect((failure as FhirError).message).toBe('Patient/x not found');
  });

  test('search calls the audited search_resources RPC with compartment, filters and paging', async () => {
    const observation: Observation = { resourceType: 'Observation', id: 'o1', status: 'final', code: {} };
    const fake = fakeSupabase({ rpc: () => ({ data: [observation], error: null }) });
    const fhir = createFhirClient(fake.client);

    const results = await fhir.search('Observation', { patientId: 'p1', where: { code: '8302-2' }, limit: 5, offset: 10, order: 'asc' });
    await fhir.search('Patient');

    expect(results).toEqual([observation]);
    expect(fake.rpcCalls).toEqual([
      {
        name: 'search_resources',
        args: { resource_type: 'Observation', patient_id: 'p1', filters: { code: '8302-2' }, max_results: 5, skip: 10, newest_first: false },
      },
      { name: 'search_resources', args: { resource_type: 'Patient' } },
    ]);
  });

  test('logAccess records a read through the RPC', async () => {
    const fake = fakeSupabase();
    const fhir = createFhirClient(fake.client);

    await fhir.logAccess('Observation', 'o1');

    expect(fake.rpcCalls).toEqual([{ name: 'log_access', args: { resource_type: 'Observation', resource_id: 'o1' } }]);
  });

  test('from exposes the table builder for a resource type', () => {
    const fake = fakeSupabase();
    const fhir = createFhirClient(fake.client);

    fhir.from('MedicationRequest');

    expect(fake.table()).toBe('medication_request');
  });
});
