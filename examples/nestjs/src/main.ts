import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { FhirExceptionFilter } from './fhir/fhir-exception.filter';

const port = Number(process.env.PORT ?? 3000);
const app = await NestFactory.create(AppModule, { logger: ['error', 'warn'] });
app.useGlobalFilters(new FhirExceptionFilter());
await app.listen(port);
console.log(`supabase-fhir NestJS example listening on http://127.0.0.1:${port}`);
