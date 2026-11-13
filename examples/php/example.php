<?php
/**
 * A minimal supabase-fhir client in PHP 8.1+, no dependencies (streams only, ext-curl not needed).
 *
 *   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... php examples/php/example.php
 *
 * Signs in as the demo clinician, lists the patients this user may see, reads one (audited),
 * searches vital signs and shows how errors carry a FHIR OperationOutcome. Pair it with a
 * FHIR model library (for example dcarbone/php-fhir) to hydrate resources into typed objects.
 */

declare(strict_types=1);

/** What PostgREST returns for failed requests, with the OperationOutcome when present. */
final class FhirError extends RuntimeException
{
    public ?array $outcome = null;

    public function __construct(
        public readonly int $status,
        public readonly ?string $errorCode,
        string $message,
        ?string $details,
    ) {
        parent::__construct("$status $errorCode: $message");
        if ($details !== null) {
            $parsed = json_decode($details, true);
            if (is_array($parsed) && ($parsed['resourceType'] ?? null) === 'OperationOutcome') {
                $this->outcome = $parsed;
            }
        }
    }
}

final class Client
{
    private ?string $token = null;

    public function __construct(private readonly string $baseUrl, private readonly string $apiKey)
    {
    }

    private function request(string $method, string $path, mixed $body = null): mixed
    {
        $headers = [
            "apikey: {$this->apiKey}",
            'Content-Type: application/json',
            ($method === 'GET' ? 'Accept-Profile' : 'Content-Profile') . ': fhir',
        ];
        if ($this->token !== null) {
            $headers[] = "Authorization: Bearer {$this->token}";
        }
        $context = stream_context_create(['http' => [
            'method' => $method,
            'header' => implode("\r\n", $headers),
            'content' => $body === null ? '' : json_encode($body, JSON_THROW_ON_ERROR),
            'ignore_errors' => true,
        ]]);

        $raw = file_get_contents($this->baseUrl . $path, false, $context);
        if ($raw === false) {
            throw new RuntimeException("request failed: $method $path");
        }
        $status = preg_match('#HTTP/\S+\s+(\d{3})#', $http_response_header[0] ?? '', $match) ? (int) $match[1] : 0;
        $data = $raw === '' ? null : json_decode($raw, true);

        if ($status >= 400) {
            throw new FhirError($status, $data['code'] ?? null, $data['message'] ?? 'request failed', $data['details'] ?? null);
        }
        return $data;
    }

    /** Exchanges email and password for a JWT (Supabase Auth password grant). */
    public function login(string $email, string $password): void
    {
        $session = $this->request('POST', '/auth/v1/token?grant_type=password', ['email' => $email, 'password' => $password]);
        $this->token = $session['access_token'];
    }

    /** Calls a function in the fhir schema: read_resource, create_resource, import_bundle, ... */
    public function rpc(string $name, array $args = []): mixed
    {
        return $this->request('POST', "/rest/v1/rpc/$name", (object) $args);
    }

    /** Reads a table with PostgREST filters: observation?patient_id=eq.123&select=resource */
    public function query(string $tableAndParams): array
    {
        return $this->request('GET', "/rest/v1/$tableAndParams") ?? [];
    }
}

$apiKey = getenv('SUPABASE_ANON_KEY');
if ($apiKey === false || $apiKey === '') {
    fwrite(STDERR, "SUPABASE_ANON_KEY is required\n");
    exit(1);
}
$client = new Client(getenv('SUPABASE_URL') ?: 'http://127.0.0.1:54321', $apiKey);
$client->login(getenv('FHIR_EMAIL') ?: 'clinician@example.com', getenv('FHIR_PASSWORD') ?: 'supabase-fhir');

$patients = $client->query('patient?select=id,family_name,birth_date&order=family_name');
printf("%d patients visible to this user\n", count($patients));
foreach ($patients as $patient) {
    printf("  %s  %-14s born %s\n", $patient['id'], $patient['family_name'], $patient['birth_date']);
}
if ($patients === []) {
    exit(0);
}

// Audited read: lands in fhir.audit_log with action = read.
$patient = $client->rpc('read_resource', ['resource_type' => 'Patient', 'id' => $patients[0]['id']]);
printf("\nread Patient/%s (version %s)\n", $patient['id'], $patient['meta']['versionId']);

// Search on generated columns; RLS keeps it inside the compartments this user may see.
$params = "observation?patient_id=eq.{$patients[0]['id']}&category_code=eq.vital-signs"
    . '&select=resource&order=effective_at.desc&limit=5';
echo "\nlatest vital signs\n";
foreach ($client->query($params) as $row) {
    $resource = $row['resource'];
    $label = $resource['code']['coding'][0]['display'] ?? '?';
    $quantity = $resource['valueQuantity'] ?? null;
    $value = $quantity === null ? '' : sprintf('%s %s', $quantity['value'], $quantity['unit'] ?? '');
    printf("  %s  %-40s %s\n", $resource['effectiveDateTime'] ?? '', $label, $value);
}

// Errors: 404 for missing or invisible resources, with an OperationOutcome in the details.
try {
    $client->rpc('read_resource', ['resource_type' => 'Patient', 'id' => 'does-not-exist']);
} catch (FhirError $error) {
    printf("\nexpected failure: %s\n  OperationOutcome: %s\n", $error->getMessage(), json_encode($error->outcome));
}
