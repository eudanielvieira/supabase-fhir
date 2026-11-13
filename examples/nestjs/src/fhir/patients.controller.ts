import { Controller, Get, Inject, Param, Query } from '@nestjs/common';
import { FhirService } from './fhir.service';

@Controller('patients')
export class PatientsController {
  // Explicit token: works with any transpiler, including ones that do not emit decorator metadata (Bun, tsx).
  constructor(@Inject(FhirService) private readonly fhir: FhirService) {}

  /** The patients this user may see; RLS does the filtering. */
  @Get()
  list() {
    return this.fhir.client.search('Patient', { limit: 50 });
  }

  /** Audited read: lands in fhir.audit_log with action = read. 404 when invisible. */
  @Get(':id')
  read(@Param('id') id: string) {
    return this.fhir.client.read('Patient', id);
  }

  /** Patient $everything as a searchset Bundle. */
  @Get(':id/everything')
  everything(@Param('id') id: string) {
    return this.fhir.client.everything(id);
  }

  /** Observations filtered on the generated search columns. */
  @Get(':id/observations')
  observations(@Param('id') id: string, @Query('code') code?: string, @Query('category') category?: string) {
    const where: Record<string, string> = {};
    if (code) where.code = code;
    if (category) where.category_code = category;
    return this.fhir.client.search('Observation', { patientId: id, where, limit: 100 });
  }
}
