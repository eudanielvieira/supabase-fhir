// A minimal supabase-fhir client in C# (.NET 8+), HttpClient and System.Text.Json only.
//
//   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... dotnet run --project examples/csharp
//
// Signs in as the demo clinician, lists the patients this user may see, reads one (audited),
// searches vital signs and shows how errors carry a FHIR OperationOutcome. Pair it with
// Firely .NET SDK (Hl7.Fhir.R4) to parse resources into typed POCOs.

using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

var apiKey = Environment.GetEnvironmentVariable("SUPABASE_ANON_KEY");
if (string.IsNullOrEmpty(apiKey))
{
    Console.Error.WriteLine("SUPABASE_ANON_KEY is required");
    return 1;
}

var client = new FhirClient(Env("SUPABASE_URL", "http://127.0.0.1:54321"), apiKey);
await client.LoginAsync(Env("FHIR_EMAIL", "clinician@example.com"), Env("FHIR_PASSWORD", "supabase-fhir"));

var patients = (await client.QueryAsync("patient?select=id,family_name,birth_date&order=family_name"))!.AsArray();
Console.WriteLine($"{patients.Count} patients visible to this user");
foreach (var p in patients)
{
    Console.WriteLine($"  {p!["id"]}  {p["family_name"],-14} born {p["birth_date"]}");
}
if (patients.Count == 0)
{
    return 0;
}
var first = patients[0]!["id"]!.GetValue<string>();

// Audited read: lands in fhir.audit_log with action = read.
var patient = (await client.RpcAsync("read_resource", new { resource_type = "Patient", id = first }))!;
Console.WriteLine($"\nread Patient/{patient["id"]} (version {patient["meta"]!["versionId"]})");

// Search on generated columns; RLS keeps it inside the compartments this user may see.
var vitals = (await client.QueryAsync(
    $"observation?patient_id=eq.{first}&category_code=eq.vital-signs&select=resource&order=effective_at.desc&limit=5"))!.AsArray();
Console.WriteLine("\nlatest vital signs");
foreach (var row in vitals)
{
    var observation = row!["resource"]!;
    var label = observation["code"]?["coding"]?[0]?["display"]?.GetValue<string>() ?? "?";
    var quantity = observation["valueQuantity"];
    var value = quantity is null ? "" : $"{quantity["value"]} {quantity["unit"]}";
    Console.WriteLine($"  {observation["effectiveDateTime"]}  {label,-40} {value}");
}

// Errors: 404 for missing or invisible resources, with an OperationOutcome in the details.
try
{
    await client.RpcAsync("read_resource", new { resource_type = "Patient", id = "does-not-exist" });
}
catch (FhirException error)
{
    Console.WriteLine($"\nexpected failure: {error.Message}\n  OperationOutcome: {error.Outcome?.ToJsonString()}");
}
return 0;

static string Env(string name, string fallback) =>
    Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : fallback;

/// <summary>What PostgREST returns for failed requests; Outcome holds the FHIR OperationOutcome when present.</summary>
sealed class FhirException : Exception
{
    public int Status { get; }
    public string? Code { get; }
    public JsonNode? Outcome { get; }

    public FhirException(int status, JsonNode? body)
        : base($"{status} {body?["code"]}: {body?["message"]}")
    {
        Status = status;
        Code = body?["code"]?.GetValue<string>();
        var details = body?["details"]?.GetValue<string>();
        if (details is null)
        {
            return;
        }
        try
        {
            var parsed = JsonNode.Parse(details);
            if (parsed?["resourceType"]?.GetValue<string>() == "OperationOutcome")
            {
                Outcome = parsed;
            }
        }
        catch (JsonException)
        {
            // details was plain text
        }
    }
}

/// <summary>Talks to PostgREST and Supabase Auth with the fhir schema selected.</summary>
sealed class FhirClient
{
    private readonly HttpClient _http = new();
    private readonly string _baseUrl;
    private readonly string _apiKey;
    private string? _token;

    public FhirClient(string baseUrl, string apiKey)
    {
        _baseUrl = baseUrl.TrimEnd('/');
        _apiKey = apiKey;
    }

    private async Task<JsonNode?> RequestAsync(HttpMethod method, string path, object? body)
    {
        using var request = new HttpRequestMessage(method, _baseUrl + path);
        request.Headers.TryAddWithoutValidation("apikey", _apiKey);
        request.Headers.TryAddWithoutValidation(method == HttpMethod.Get ? "Accept-Profile" : "Content-Profile", "fhir");
        if (_token is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        }
        if (body is not null)
        {
            request.Content = JsonContent.Create(body);
        }

        using var response = await _http.SendAsync(request);
        var raw = await response.Content.ReadAsStringAsync();
        var json = string.IsNullOrWhiteSpace(raw) ? null : JsonNode.Parse(raw);
        if ((int)response.StatusCode >= 400)
        {
            throw new FhirException((int)response.StatusCode, json);
        }
        return json;
    }

    /// <summary>Exchanges email and password for a JWT (Supabase Auth password grant).</summary>
    public async Task LoginAsync(string email, string password)
    {
        var session = await RequestAsync(HttpMethod.Post, "/auth/v1/token?grant_type=password", new { email, password });
        _token = session!["access_token"]!.GetValue<string>();
    }

    /// <summary>Calls a function in the fhir schema: read_resource, create_resource, import_bundle, ...</summary>
    public Task<JsonNode?> RpcAsync(string name, object args) =>
        RequestAsync(HttpMethod.Post, $"/rest/v1/rpc/{name}", args);

    /// <summary>Reads a table with PostgREST filters: observation?patient_id=eq.123&amp;select=resource</summary>
    public Task<JsonNode?> QueryAsync(string tableAndParams) =>
        RequestAsync(HttpMethod.Get, $"/rest/v1/{tableAndParams}", null);
}
