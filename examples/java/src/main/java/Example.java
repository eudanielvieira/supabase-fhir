import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Map;

/**
 * A minimal supabase-fhir client in Java 17+: the JDK HttpClient plus Jackson for JSON.
 *
 *   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... mvn -q compile exec:java
 *
 * Signs in as the demo clinician, lists the patients this user may see, reads one (audited),
 * searches vital signs and shows how errors carry a FHIR OperationOutcome. Pair it with
 * HAPI FHIR structures to parse resources into typed objects.
 */
public final class Example {

    /** What PostgREST returns for failed requests; outcome holds the FHIR OperationOutcome when present. */
    static final class FhirException extends RuntimeException {
        final int status;
        final String code;
        final JsonNode outcome;

        FhirException(int status, JsonNode body, ObjectMapper mapper) {
            super(status + " " + body.path("code").asText() + ": " + body.path("message").asText());
            this.status = status;
            this.code = body.path("code").asText(null);
            JsonNode parsed = null;
            String details = body.path("details").asText(null);
            if (details != null) {
                try {
                    JsonNode candidate = mapper.readTree(details);
                    if ("OperationOutcome".equals(candidate.path("resourceType").asText())) {
                        parsed = candidate;
                    }
                } catch (IOException ignored) {
                    // details was plain text
                }
            }
            this.outcome = parsed;
        }
    }

    static final class Client {
        private final String baseUrl;
        private final String apiKey;
        private final HttpClient http = HttpClient.newHttpClient();
        private final ObjectMapper mapper = new ObjectMapper();
        private String token;

        Client(String baseUrl, String apiKey) {
            this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
            this.apiKey = apiKey;
        }

        private JsonNode request(String method, String path, Object body) throws IOException, InterruptedException {
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(baseUrl + path))
                    .header("apikey", apiKey)
                    .header("Content-Type", "application/json")
                    .header(method.equals("GET") ? "Accept-Profile" : "Content-Profile", "fhir");
            if (token != null) {
                builder.header("Authorization", "Bearer " + token);
            }
            HttpRequest.BodyPublisher publisher = body == null
                    ? HttpRequest.BodyPublishers.noBody()
                    : HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(body));
            HttpResponse<String> response = http.send(builder.method(method, publisher).build(),
                    HttpResponse.BodyHandlers.ofString());
            JsonNode json = response.body().isBlank() ? mapper.nullNode() : mapper.readTree(response.body());
            if (response.statusCode() >= 400) {
                throw new FhirException(response.statusCode(), json, mapper);
            }
            return json;
        }

        /** Exchanges email and password for a JWT (Supabase Auth password grant). */
        void login(String email, String password) throws IOException, InterruptedException {
            JsonNode session = request("POST", "/auth/v1/token?grant_type=password",
                    Map.of("email", email, "password", password));
            token = session.path("access_token").asText();
        }

        /** Calls a function in the fhir schema: read_resource, create_resource, import_bundle, ... */
        JsonNode rpc(String name, Map<String, ?> args) throws IOException, InterruptedException {
            return request("POST", "/rest/v1/rpc/" + name, args);
        }

        /** Reads a table with PostgREST filters: observation?patient_id=eq.123&select=resource */
        JsonNode query(String tableAndParams) throws IOException, InterruptedException {
            return request("GET", "/rest/v1/" + tableAndParams, null);
        }
    }

    public static void main(String[] args) throws Exception {
        String apiKey = System.getenv("SUPABASE_ANON_KEY");
        if (apiKey == null || apiKey.isBlank()) {
            System.err.println("SUPABASE_ANON_KEY is required");
            System.exit(1);
        }
        Client client = new Client(env("SUPABASE_URL", "http://127.0.0.1:54321"), apiKey);
        client.login(env("FHIR_EMAIL", "clinician@example.com"), env("FHIR_PASSWORD", "supabase-fhir"));

        JsonNode patients = client.query("patient?select=id,family_name,birth_date&order=family_name");
        System.out.printf("%d patients visible to this user%n", patients.size());
        for (JsonNode patient : patients) {
            System.out.printf("  %s  %-14s born %s%n", patient.path("id").asText(),
                    patient.path("family_name").asText(), patient.path("birth_date").asText());
        }
        if (patients.isEmpty()) {
            return;
        }
        String first = patients.get(0).path("id").asText();

        // Audited read: lands in fhir.audit_log with action = read.
        JsonNode patient = client.rpc("read_resource", Map.of("resource_type", "Patient", "id", first));
        System.out.printf("%nread Patient/%s (version %s)%n", patient.path("id").asText(),
                patient.path("meta").path("versionId").asText());

        // Search on generated columns; RLS keeps it inside the compartments this user may see.
        JsonNode vitals = client.query("observation?patient_id=eq." + first
                + "&category_code=eq.vital-signs&select=resource&order=effective_at.desc&limit=5");
        System.out.printf("%nlatest vital signs%n");
        for (JsonNode row : vitals) {
            JsonNode observation = row.path("resource");
            String label = observation.path("code").path("coding").path(0).path("display").asText("?");
            JsonNode quantity = observation.path("valueQuantity");
            String value = quantity.isMissingNode() ? ""
                    : quantity.path("value").asText() + " " + quantity.path("unit").asText("");
            System.out.printf("  %s  %-40s %s%n", observation.path("effectiveDateTime").asText(""), label, value);
        }

        // Errors: 404 for missing or invisible resources, with an OperationOutcome in the details.
        try {
            client.rpc("read_resource", Map.of("resource_type", "Patient", "id", "does-not-exist"));
        } catch (FhirException error) {
            System.out.printf("%nexpected failure: %s%n  OperationOutcome: %s%n", error.getMessage(), error.outcome);
        }
    }

    private static String env(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
