import { type ArgumentsHost, Catch, type ExceptionFilter } from '@nestjs/common';
import type { Response } from 'express';
import { FhirError } from '../../../../packages/typescript/src';

/** Turns a FhirError into the HTTP status and OperationOutcome the database already produced. */
@Catch(FhirError)
export class FhirExceptionFilter implements ExceptionFilter<FhirError> {
  catch(error: FhirError, host: ArgumentsHost): void {
    const response = host.switchToHttp().getResponse<Response>();
    response.status(error.status).json(
      error.outcome ?? {
        resourceType: 'OperationOutcome',
        issue: [{ severity: 'error', code: 'exception', diagnostics: error.message }],
      },
    );
  }
}
