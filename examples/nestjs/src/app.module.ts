import { Module } from '@nestjs/common';
import { FhirModule } from './fhir/fhir.module';

@Module({ imports: [FhirModule] })
export class AppModule {}
