# supabase-fhir

[Read this in English](README.md)

FHIR R4 no Supabase, pronto para clonar. Schema Postgres, segurança por linha (RLS) por paciente,
log de auditoria, histórico de versões e uma API no estilo FHIR, com pacientes sintéticos do Synthea
já carregados. Postgres primeiro: as regras vivem no banco, então qualquer linguagem conversa com
ele por HTTP ou SQL.

[![ci](https://github.com/eudanielvieira/supabase-fhir/actions/workflows/ci.yml/badge.svg)](https://github.com/eudanielvieira/supabase-fhir/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Todo produto de saúde no Supabase começa reconstruindo a mesma base: como guardar recursos FHIR
no Postgres, como garantir que um paciente veja só os próprios dados, como provar quem leu o quê.
Este repositório é essa base, escrita uma vez, testada e livre para copiar.

> Somente dados sintéticos. Todo paciente deste repositório foi gerado pelo
> [Synthea](https://synthea.mitre.org). Não existe dado real de paciente aqui, e nunca vai existir.

## O que você recebe

| Peça | Onde | O que faz |
|---|---|---|
| Schema | `supabase/migrations/` | Uma tabela por tipo de recurso (`fhir.patient`, `fhir.observation`, ...): o recurso completo em JSONB mais colunas de busca indexadas |
| Controle de acesso | `fhir.patient_access` e políticas de RLS | Um usuário vê apenas os compartimentos de paciente que recebeu. Admins veem tudo. Anônimo não vê nada |
| Log de auditoria | `fhir.audit_log` | Toda criação, atualização, exclusão e leitura auditada: quem, quando, qual recurso, qual paciente, de onde |
| Histórico | `fhir.resource_history` | Toda versão anterior de todo recurso, no estilo `_history` do FHIR |
| Operações FHIR | funções RPC `fhir.*` | read, create, update com lock otimista, delete, history, `$everything` do Patient, importação de Bundle. Erros são `OperationOutcome` FHIR |
| Contrato HTTP | [`docs/api.md`](docs/api.md) | Cada chamada em `curl`, mais o documento OpenAPI que o PostgREST serve. Funciona em qualquer linguagem |
| Clientes | `packages/typescript/`, `examples/` | Um cliente TypeScript tipado, backends NestJS e Elysia que repassam o JWT do usuário, e exemplos sem dependências em Go, Python, PHP, Java, C# e Ruby |
| Postgres puro | `sql/compat/`, `sql/dist/` | Rode sem Supabase: uma camada de compatibilidade e o schema em um arquivo só |
| Dados sintéticos | `supabase/seeds/` | 4 pacientes Synthea com mais de 500 recursos, os prestadores que eles referenciam e 3 logins de demonstração |
| Testes | `supabase/tests/`, `tests/http/`, `packages/typescript/tests/` | 111 asserções pgTAP, uma suíte de conformidade HTTP via PostgREST e testes unitários do cliente |

## Casos de uso

O que o starter foi feito para resolver, em palavras simples. A lista completa, com prioridades, e as
decisões por trás do desenho estão em [docs/design](docs/design) (em inglês).

- Um dev provisiona um banco pronto para FHIR com um `supabase db reset` e adiciona tipos de recurso com uma chamada SQL.
- Um paciente entra e vê o próprio prontuário e nada mais, com a garantia vindo do banco.
- Um profissional lê e escreve nos pacientes que lhe foram concedidos, enquanto a concessão vale.
- Um admin concede e revoga acesso, lê o log de auditoria e mantém os dados de referência.
- Um revisor de compliance responde "quem mexeu neste paciente e quando" com `fhir.audit_log` e `fhir.history()`.
- Um backend importa Bundles FHIR do Synthea ou de um prontuário eletrônico, com referências resolvidas e importação idempotente.
- Qualquer app, em qualquer linguagem, usa o mesmo contrato HTTP: TypeScript, Go, Python, PHP, Java, C#, Ruby, ou um cliente gerado a partir do OpenAPI.
- Um backend (NestJS, Elysia ou qualquer framework) repassa o JWT do usuário e deixa o banco aplicar o acesso, em vez de guardar a service role key.

## Começando

Precisa de Docker e [Bun](https://bun.sh). Node 20 com npm também funciona: troque `bun` por `npm` e `npx`.

```bash
git clone https://github.com/eudanielvieira/supabase-fhir.git
cd supabase-fhir
bun install
bun run db:start      # sobe o Supabase local, aplica migrations e seeds
```

O `db:start` imprime a URL da API, a anon key e a service role key. Abra o Studio em
http://127.0.0.1:54323, escolha o schema `fhir` e os pacientes já estão lá.

Logins de demonstração (só local, senha `supabase-fhir` para os três):

| E-mail | Papel | Enxerga |
|---|---|---|
| `patient@example.com` | paciente | o próprio prontuário e nada mais |
| `clinician@example.com` | profissional | os quatro pacientes carregados, leitura e escrita |
| `admin@example.com` | admin | tudo, inclusive o log de auditoria |

Depois, escolha uma linguagem.

**curl** (o contrato sobre o qual todo o resto é construído, veja [docs/api.md](docs/api.md)):

```bash
JWT=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" -d '{"email":"clinician@example.com","password":"supabase-fhir"}' | jq -r .access_token)

curl -s "$SUPABASE_URL/rest/v1/patient?select=id,family_name,birth_date" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $JWT" -H "Accept-Profile: fhir"

curl -s "$SUPABASE_URL/rest/v1/rpc/read_resource" -H "Content-Profile: fhir" -H "Content-Type: application/json" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $JWT" -d '{"resource_type":"Patient","id":"<id>"}'
```

**TypeScript** (`packages/typescript/`):

```ts
import { createClient } from '@supabase/supabase-js';
import { createFhirClient, type Database } from './packages/typescript/src';

const supabase = createClient<Database>(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!);
await supabase.auth.signInWithPassword({ email: 'clinician@example.com', password: 'supabase-fhir' });

const fhir = createFhirClient(supabase);
const patients = await fhir.search('Patient');                      // só os que este usuário pode ver
const patient = await fhir.read('Patient', patients[0]!.id!);       // leitura auditada
const vitals = await fhir.search('Observation', { patientId: patient.id!, where: { category_code: 'vital-signs' }, limit: 20 });
const bundle = await fhir.everything(patient.id!);                  // $everything do Patient
```

**Um backend na frente**: [examples/nestjs](examples/nestjs) e [examples/elysia](examples/elysia)
repassam o JWT de quem chama, então a RLS roda como o usuário final e a API nunca guarda a service role key.

**Go, Python, PHP, Java, C#, Ruby**: `bun run example:go` (ou `example:python`, `example:php`,
`example:java`, `example:csharp`, `example:ruby`). Cada um cabe em uma tela e usa a biblioteca
padrão da linguagem (Java acrescenta o Jackson para JSON). Veja [examples/](examples).

**Qualquer outra coisa**: gere um cliente a partir do documento OpenAPI que o PostgREST serve, ou
chame as RPCs direto em SQL. Os dois caminhos estão em [docs/api.md](docs/api.md).

## Isso é uma biblioteca?

Não, e essa é a ideia. O produto é o banco: migrations que você aplica no Supabase (ou em qualquer
Postgres, com a camada de compatibilidade) e um contrato HTTP que qualquer linguagem usa. O cliente
TypeScript é um adaptador entre vários e pode virar pacote npm mais tarde. Veja
[Usando no seu projeto](#usando-no-seu-projeto).

## Como os dados são guardados

Cada tipo de recurso ganha a própria tabela, todas com o mesmo formato, criadas por uma função:

```sql
select fhir.define_resource('Specimen');          -- escopado por paciente (padrão)
select fhir.define_resource('Substance', false);  -- dado de referência, legível por qualquer usuário logado
```

| Coluna | Tipo | Significado |
|---|---|---|
| `id` | text | O id FHIR. UUID por padrão; um id que você informar é mantido |
| `version_id` | integer | Começa em 1 e soma um a cada atualização |
| `last_updated` | timestamptz | Definido a cada escrita |
| `resource` | jsonb | O recurso FHIR completo. `id`, `meta.versionId` e `meta.lastUpdated` ficam sincronizados automaticamente |
| `patient_id` | text, gerado | O compartimento do paciente, extraído de `subject`, `patient`, `beneficiary` ou de um `target` do tipo Patient. A RLS usa essa coluna |
| `created_at`, `created_by`, `updated_by` | | Quando e por quem (`auth.uid()`) |

Colunas de busca geradas cobrem os parâmetros de busca FHIR mais comuns, então os filtros ficam em SQL e batem em índice:

| Tabela | Colunas de busca |
|---|---|
| `patient` | `family_name`, `birth_date`, `gender`, `active` |
| `encounter` | `status`, `class_code`, `type_code`, `period_start`, `period_end` |
| `condition` | `clinical_status`, `verification_status`, `code`, `code_system`, `onset_at`, `abatement_at`, `encounter_id` |
| `observation` | `status`, `category_code`, `code`, `code_system`, `effective_at`, `value_quantity`, `value_unit`, `encounter_id` |
| `procedure`, `immunization`, `diagnostic_report`, `medication_request` e outras | veja `supabase/migrations/*_fhir_resources.sql` |

```sql
-- medições de pressão arterial de um paciente desde 2024
select resource
from fhir.observation
where patient_id = $1 and code = '85354-9' and effective_at >= '2024-01-01';
```

Qualquer outra coisa é uma consulta JSONB com um índice GIN por trás:

```sql
select id from fhir.patient
where resource @> '{"identifier":[{"system":"http://hl7.org/fhir/sid/us-ssn"}]}';
```

Tipos de recurso incluídos (26): Patient, Practitioner, PractitionerRole, Organization, Location,
Medication, Encounter, Condition, Observation, Procedure, MedicationRequest, MedicationAdministration,
Immunization, AllergyIntolerance, DiagnosticReport, DocumentReference, CarePlan, CareTeam, Goal,
Device, ImagingStudy, SupplyDelivery, Coverage, Claim, ExplanationOfBenefit, Provenance.

## Quem vê o quê

O acesso é decidido no banco, por compartimento de paciente. Quatro tipos de chamador:

| Chamador | Identificado por | Recursos ligados a paciente | Dados de referência (Practitioner, Organization, ...) | Log de auditoria |
|---|---|---|---|---|
| Paciente ou profissional | linhas em `fhir.patient_access` | lê ou escreve nos compartimentos concedidos enquanto a concessão vale | lê | não |
| Admin | JWT com `app_metadata.fhir_role = 'admin'` | tudo | lê e escreve | lê |
| Service role | service role key, só no servidor | ignora a RLS | ignora a RLS | ignora a RLS |
| Anônimo | sem sessão | nada, nem o schema | nada | nada |

Conceder acesso é inserir uma linha:

```sql
-- um usuário do portal do paciente vê o próprio prontuário
insert into fhir.patient_access (user_id, patient_id, access_level, reason)
values ('<auth.users.id>', '<patient id>', 'read', 'patient portal');

-- um profissional cobrindo o plantão desta noite
insert into fhir.patient_access (user_id, patient_id, access_level, valid_until, reason)
values ('<auth.users.id>', '<patient id>', 'write', now() + interval '12 hours', 'on call');
```

Tornar alguém admin é uma claim em `app_metadata`, que o próprio usuário não consegue editar:

```sql
update auth.users
set raw_app_meta_data = raw_app_meta_data || '{"fhir_role": "admin"}'
where email = 'admin@example.com';
```

O mesmo a partir de um servidor: `supabase.auth.admin.updateUserById(id, { app_metadata: { fhir_role: 'admin' } })`.

Linhas sem paciente (uma Observation sem `subject`, por exemplo) ficam visíveis só para admins.
`fhir.has_patient_access(patient_id, 'write')` existe para as suas próprias políticas e verificações.

## Log de auditoria e histórico

As escritas são auditadas por triggers, então não há como passar por fora:

```sql
select occurred_at, action, resource_type, resource_id, actor_id, actor_role, request
from fhir.audit_log
where patient_id = '<patient id>'
order by occurred_at desc;
```

As leituras são auditadas quando passam por `fhir.read_resource()` ou `fhir.patient_everything()`,
que é o que os clientes usam. Um `select` puro via PostgREST não é auditado por linha, porque o
Postgres não tem trigger de select. Para esses casos, use os logs da API do Supabase ou direcione
as leituras pelas RPCs. O log guarda apenas identificadores, nunca o conteúdo do recurso.

O histórico guarda toda versão substituída, inclusive a última antes de uma exclusão:

```sql
select version_id, operation, last_updated, resource
from fhir.history('Patient', '<id>');
```

## Operações FHIR e erros

Cada operação é uma função Postgres, chamada como `POST /rest/v1/rpc/<nome>` ou direto em SQL.
Elas rodam como o usuário logado, então a RLS sempre se aplica. [docs/api.md](docs/api.md)
traz o contrato completo com exemplos em `curl`; a versão curta:

| Função | Faz |
|---|---|
| `read_resource(resource_type, id)` | devolve o recurso e registra uma leitura |
| `create_resource(resource)` | insere e devolve o recurso gravado com `id` e `meta` |
| `update_resource(resource, expected_version)` | substituição completa; `expected_version` dá lock otimista (If-Match) |
| `delete_resource(resource_type, id)` | exclui; a última versão fica no histórico |
| `history(resource_type, id)` | todas as versões, da mais nova para a mais antiga |
| `patient_everything(patient_id)` | um Bundle com todo o compartimento que o chamador pode ver |
| `import_bundle(bundle)` | importação transaction ou batch: resolve referências `urn:uuid` e `Type?identifier=`, respeita `ifNoneExist`, faz upsert por id |

Os erros voltam com status HTTP (400, 403, 404, 409) e um `OperationOutcome` FHIR no campo
`details` da resposta, então uma biblioteca FHIR em qualquer linguagem os entende. "Não encontrado"
e "sem permissão" respondem 404 igualmente, para que ids não possam ser enumerados.

## Clientes

| Linguagem | Onde | Observações |
|---|---|---|
| TypeScript | `packages/typescript/` | Tipo `Database` para o supabase-js com `resource` tipado por tabela via `@types/fhir`, e `createFhirClient()` com `read`, `create`, `update`, `remove`, `history`, `search`, `everything`, `importBundle`. Erros são `FhirError` com `status` e `outcome` |
| NestJS | `examples/nestjs/` | `FhirService` com escopo de requisição montado a partir do header `Authorization`, filtro de exceção que mapeia `FhirError` para status mais OperationOutcome, um controller `patients` |
| Elysia (Bun) | `examples/elysia/` | o mesmo padrão em 70 linhas: `derive` monta o cliente por requisição, `onError` mapeia os erros |
| Go | `examples/go/` | biblioteca padrão. Login, listagem, leitura auditada, busca, tratamento de erro |
| Python | `examples/python/` | o mesmo fluxo, biblioteca padrão; encaixa em Django ou FastAPI |
| PHP | `examples/php/` | o mesmo fluxo, PHP 8.1+ só com streams; encaixa em Laravel ou Symfony |
| Java | `examples/java/` | `HttpClient` do JDK mais Jackson, Maven; vira um bean no Spring |
| C# | `examples/csharp/` | .NET 8, `HttpClient` e `System.Text.Json`; registre via `IHttpClientFactory` no ASP.NET Core |
| Ruby | `examples/ruby/` | `net/http` e `json`; vira um service object no Rails |
| Outras | `docs/api.md` | gere a partir do OpenAPI, ou chame as funções em SQL com as claims do usuário definidas |

O tipo `Database` do TypeScript se combina com o seu: `type Database = AppDatabase & FhirDatabase`.

## Dados sintéticos

Os seeds vêm do conjunto de amostra do Synthea: 4 pacientes e as 32 organizações, locais e
profissionais que eles referenciam. `bun run db:reset` restaura tudo a qualquer momento.

Para carregar mais pacientes, local ou em um projeto hospedado:

```bash
# 1. obtenha os bundles: o conjunto público de amostra, ou gere os seus com o Synthea
curl -L -o synthea.zip https://synthetichealth.github.io/synthea-sample-data/downloads/latest/synthea_sample_data_fhir_latest.zip
mkdir -p data/synthea/fhir && unzip -q synthea.zip -d data/synthea/fhir

# 2. importe via fhir.import_bundle com a service role key
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_SERVICE_ROLE_KEY=... \
  bun run seed:synthea --dir data/synthea/fhir --limit 25
```

`bun run seed:build --dir data/synthea/fhir` regenera os seeds commitados a partir de um diretório desses.

## Testes

```bash
bun test            # domínio e cliente, sem banco
bun run test:db     # pgTAP contra o banco local: RLS, triggers, importação, API
bun run test:http   # as mesmas garantias vistas de fora, via PostgREST (precisa da stack no ar)
```

A suíte pgTAP é o contrato: um paciente não lê outro compartimento, concessões só de leitura não
escrevem, concessões expiradas param de funcionar, anônimo não recebe nada, `user_metadata` não
forja um admin, toda escrita é versionada e auditada. A suíte HTTP confere que qualquer cliente vê
exatamente isso. O CI roda tudo a cada push e compila ou valida cada exemplo.

## Usando no seu projeto

**No Supabase**

1. Copie `supabase/migrations/*_fhir_*.sql` para o seu `supabase/migrations/`, mantendo a ordem
   (ou aplique `sql/dist/supabase-fhir.sql` como uma migration única).
2. Exponha o schema: adicione `"fhir"` em `schemas` dentro de `[api]` no `supabase/config.toml` e,
   em projetos hospedados, em Project Settings > API > Exposed schemas.
3. Rode `supabase db push`, insira as linhas de acesso dos seus usuários e defina a claim de admin dos operadores.
4. Escolha um cliente: copie `packages/typescript/src/`, adapte um exemplo ou gere um a partir do OpenAPI.
5. Deixe `supabase/seeds/` de fora: usuários demo e pacientes sintéticos são só para desenvolvimento local.

**Em Postgres puro** (qualquer host, com ou sem PostgREST)

1. Rode `sql/compat/plain-postgres.sql` uma vez como superusuário: ele cria os papéis e os helpers
   `auth` de que as políticas dependem.
2. Aplique `sql/dist/supabase-fhir.sql`.
3. Coloque o PostgREST na frente (`db-schemas = fhir`) e emita os JWTs você mesmo, ou conecte a partir
   do seu backend e defina as claims do usuário por transação, como mostra [docs/api.md](docs/api.md).

Precisa de outro tipo de recurso? Uma linha de migration, mais uma entrada em `TABLE_NAMES` e `ResourceMap`
em `packages/typescript/src/domain/resource-types.ts` se usar o cliente TypeScript:

```sql
select fhir.define_resource('Specimen');
alter table fhir.specimen
  add column status text generated always as (resource ->> 'status') stored;
```

## Limites e roadmap

- Sem validação de perfis (US Core e afins). O banco confere estrutura e ids, e não conformidade.
- Sem escopos SMART on FHIR. Supabase Auth mais `patient_access` cobre apps de paciente e de profissional.
- Multi-tenant (um banco, várias organizações) está planejado por cima do modelo de compartimentos.
- Uma fachada FHIR REST (`GET /fhir/Patient/{id}`, `GET /fhir/Observation?patient=...`), para que SDKs
  FHIR prontos funcionem sem mudanças, é o próximo marco (UC-028 no backlog).
- `_history` e `$everything` já existem; `$export` ainda não.

Nota de compliance: este projeto entrega os controles técnicos (isolamento, auditoria, versionamento).
Conformidade com HIPAA ou PIPEDA também depende do seu plano Supabase e do BAA, do manuseio de chaves,
da retenção e dos processos. Converse com a pessoa responsável por compliance antes de guardar PHI real.

## Contribuindo

Veja [CONTRIBUTING.md](CONTRIBUTING.md). Agentes de IA: leiam [AGENTS.md](AGENTS.md) primeiro.

## Licença

MIT. O Synthea é Apache 2.0 e seus dados de amostra são livres para uso.
