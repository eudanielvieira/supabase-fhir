import { Inject, Injectable, Scope, UnauthorizedException } from '@nestjs/common';
import { REQUEST } from '@nestjs/core';
import { createClient } from '@supabase/supabase-js';
import type { Request } from 'express';
import { createFhirClient, type Database, type FhirClient } from '../../../../clients/typescript/src';
import { env } from '../config';

/**
 * One FHIR client per request, carrying the caller's JWT.
 *
 * Supabase evaluates row level security as that user, so this API never holds the
 * service role key and never reimplements "who may see which patient": the database
 * decides, exactly as it does for a browser talking to Supabase directly.
 */
@Injectable({ scope: Scope.REQUEST })
export class FhirService {
  readonly client: FhirClient;

  constructor(@Inject(REQUEST) request: Request) {
    const authorization = request.headers.authorization;
    if (!authorization?.startsWith('Bearer ')) {
      throw new UnauthorizedException('Bearer token required');
    }
    const supabase = createClient<Database>(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    this.client = createFhirClient(supabase);
  }
}
