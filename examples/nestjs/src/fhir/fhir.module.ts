import { Module } from '@nestjs/common';
import { FhirService } from './fhir.service';
import { PatientsController } from './patients.controller';

@Module({
  controllers: [PatientsController],
  providers: [FhirService],
})
export class FhirModule {}
