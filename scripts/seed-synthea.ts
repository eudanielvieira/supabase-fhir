#!/usr/bin/env bun
/**
 * Loads a directory of Synthea FHIR R4 bundles into a Supabase project through fhir.import_bundle.
 *
 *   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_SERVICE_ROLE_KEY=... \
 *     bun run seed:synthea --dir ./output/fhir --limit 50
 *
 * Provider bundles (hospitalInformation*, practitionerInformation*) are imported first so that
 * conditional references from patient bundles resolve. Imports are idempotent (upsert by id).
 */
import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import type { Bundle } from 'fhir/r4';
import { createFhirClient, type Database } from '../src';

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    dir: { type: 'string', default: 'data/synthea/fhir' },
    limit: { type: 'string' },
    help: { type: 'boolean', default: false },
  },
});

if (values.help) {
  console.log('usage: bun run seed:synthea --dir <synthea output dir> [--limit <patients>]');
  process.exit(0);
}

const url = process.env.SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !serviceRoleKey) {
  console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required (service role bypasses RLS for seeding).');
  process.exit(1);
}

const dir = values.dir!;
const limit = values.limit ? Number.parseInt(values.limit, 10) : Number.POSITIVE_INFINITY;

const isProvider = (name: string) => /^(hospital|practitioner)Information/.test(name);
const files = (await readdir(dir)).filter((name) => name.endsWith('.json')).sort();
const providers = files.filter(isProvider);
const patients = files.filter((name) => !isProvider(name)).slice(0, limit);

const supabase = createClient<Database>(url, serviceRoleKey, { auth: { persistSession: false } });
const fhir = createFhirClient(supabase);

let resources = 0;
const started = performance.now();

for (const name of [...providers, ...patients]) {
  const path = join(dir, name);
  const size = (await stat(path)).size;
  const bundle = (await Bun.file(path).json()) as Bundle;
  const response = await fhir.importBundle(bundle);
  const count = response.entry?.length ?? 0;
  resources += count;
  console.log(`${name.padEnd(80)} ${String(count).padStart(5)} resources  ${(size / 1024).toFixed(0).padStart(6)} KB`);
}

const seconds = ((performance.now() - started) / 1000).toFixed(1);
console.log(`\nimported ${resources} resources from ${providers.length} provider and ${patients.length} patient bundles in ${seconds}s`);
