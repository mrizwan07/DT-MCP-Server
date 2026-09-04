# Dynatrace Managed — Copilot/Claude Instructions (Deep API v2 Reference)

Purpose: give the AI assistant enough concrete knowledge of the Dynatrace Managed v2
REST API surface — endpoints, selector syntax, key parameters, response
fields, and limits — that it can go straight to the *correct, narrowly
scoped* MCP tool call on the first try, instead of trial-and-error probing.
This is what closes the gap with Davis CoPilot (SaaS): Davis is fast because
it already "knows" the schema; this file gives the assistant the same schema
knowledge for Managed's v2 APIs.

Server: `dynatrace-oss/dynatrace-managed-mcp`. It wraps the 9 API domains
below as MCP tools, all against `{apiEndpointUrl}/e/{environmentId}/api/v2/...`.


---

## How to use this file (read this first)

For every user question, follow this flow — don't skip straight to guessing
an endpoint:

1. **Identify the domain(s)** the question touches: topology (§1), incidents/
   RCA (§2), metrics/time series (§3), logs (§4), events (§5), vulnerabilities
   (§6), config-change history (§7), SLOs (§8), or network zones (§9). Most
   real questions ("why is X slow", "what's broken") touch more than one —
   if so, go to **§10**, which is the pre-built multi-domain workflow.
2. **Jump to that section.** Each section gives you the exact selector
   grammar, required/default parameters, response shape, and a worked
   pattern — don't reconstruct syntax from memory or from general Dynatrace
   SaaS knowledge; Managed's base URL and some limits differ.
3. **Check §0's limits cheat sheet** before sending the call, so you don't
   build a query that will be silently truncated or rejected.
4. **Build one shaped call** (entity type/selector, time range, `fields`)
   and send it — don't call broad-then-narrow.
5. If the answer needs more than one domain (e.g. an RCA), follow §10's
   ordered workflow rather than free-styling the call sequence.

---

## 0. Non-negotiable efficiency rules

1. **One shaped call, not several exploratory ones.** Before calling a tool,
   decide: entity type(s), selector, time range, and `fields` — then call
   once. Don't call broad-then-narrow; go straight to the narrow call using
   the syntax below.
2. **Always pass `from` explicitly (and `to` if not "now").** Do not rely on
   each API's implicit default — defaults are *not* uniform across APIs (see
   the cheat sheet below) and silently returning a narrower or wider window
   than intended is a common cause of "entity/problem/event not found."
   Pick a window sized to the question, and if the user gave one, use it
   verbatim instead of a default.
3. **Always scope with `entitySelector`/`problemSelector`/etc.** — never
   fetch "everything" and filter client-side. Every API below accepts a
   selector; use it.
4. **Request only the fields you need** via `fields=` (Problems, Entities,
   Security Problems all support sparse fieldsets with `+field` to add to
   defaults). Smaller payloads = faster round trip = faster answer.
5. **Respect hard platform limits** (design queries so you never hit these).

   | Limit | Value | Applies to |
   |---|---|---|
   | `entitySelector` string length | max **2,000 characters** | Entities, Problems, Metrics, Events, Logs |
   | `entitySelector` — entities matched per query | **10,000** (Entities API, Events API) vs **5,000** (Metrics API) — *not the same number on every endpoint* | see §1 / §3.5 / §5.4 |
   | `problemSelector`/SLO selector string length | max **1,000 characters** | Problems (`problemSelector`), SLO (`filter`) |
   | `problemSelector text()` search term | max **30 characters**, escape `"`/`~` with `~` | Problems |
   | Metrics per query | max **10 metrics** | Metrics |
   | Metrics tuples per query | max **100,000** (extras dropped, `:sort` ignored for the cutoff) | Metrics |
   | Metrics data points per tuple | max **10,080** | Metrics |
   | Metrics total data points per query | max **20,000,000** | Metrics |
   | Audit log retention | **30 days** | Audit Logs |
   | Log Classic v2 retention | up to **35 days** (tenant-configurable — confirm, don't assume max) | Logs |
   | MCP server rate limit | default **20 calls / 20 seconds** (`DT_MCP_RATE_LIMIT_MAX_CALLS`/`DT_MCP_RATE_LIMIT_WINDOW_MS`) | all tools — batch filters into one call rather than looping |
   | Events ingest — problem-opening event `startTime` | ≤6h in the past, ≤5min in the future | Events ingest |
   | Events ingest — info-style event `startTime` | ≤30 days in the past, ≤7 days in the future | Events ingest |

   **Default `from`/`to` window differs by API — don't assume one value:**

   | API | Implicit default if you omit `from` | `to` default |
   |---|---|---|
   | Entities | `now-7d` | now |
   | Problems | `now-24h` | now |
   | Metrics query | `now-24h` | now |
   | Events | `now-24h` | now |
   | Logs | *required* — no implicit default | *required* |
   | Audit Logs | *required* — no implicit default | *required* |

   This is exactly why rule 2 says pass `from`/`to` explicitly: relying on
   memory of "the" default across APIs is a guaranteed source of mismatched
   results (e.g. an entity genuinely present in Smartscape but not seen in
   the last 2h will look "missing" if you apply the Problems default instead
   of Entities' 3-day one).

6. **Page deliberately.** Use `pageSize` + `nextPageKey` (cursor pattern,
   used by Entities, Problems, Events, Audit Logs, Security Problems). Don't
   assume page 1 is complete for a "how many / list all" question. **When
   `nextPageKey` is set, omit every other query parameter** — the cursor
   already encodes the original query. This applies to every paginated
   endpoint in this file.
7. **Answer with the API's own vocabulary** (status values, severity
   levels, entity types) — don't paraphrase into invented categories.

---

## 1. Entities API v2 — Smartscape topology

**Base (Managed):** `https://{your-activegate-domain}:9999/e/{your-environment-id}/api/v2/entities`, `/api/v2/entities/{entityId}`, `/api/v2/entityTypes`, `/api/v2/entityTypes/{type}`
Auth: token with `entities.read` scope (PAT: `environment:roles:viewer`).

| Call | Use for |
|---|---|
| `GET /api/v2/entityTypes` | Discover every entity type in *this* tenant, plus each type's valid `properties[]`, `tags`, and — critically — its `fromRelationships[]`/`toRelationships[]` names. Call once per session if relationship/property names are unknown; cache mentally for the rest of the conversation. Paginated via `nextPageKey`, `pageSize` default 50, max 500. |
| `GET /api/v2/entityTypes/{type}` | Same, scoped to one type — cheaper when the type is already known. Response includes `dimensionKey` (the key used to join this type into Metrics API v2 results — needed when correlating an entity to its metrics), `properties[]` (`{id, type}`), `fromRelationships[]`/`toRelationships[]` (`{id, toTypes[]/fromTypes[]}`). |
| `GET /api/v2/entities?entitySelector=...` | The core topology list query. `entitySelector` is **required** on the first page of any query (only omit it, and every other param, when paging via `nextPageKey`). |
| `GET /api/v2/entities/{entityId}` | Full property/relationship set for **one** known entity — use when you already have the ID and want depth (e.g. after resolving a problem's `rootCauseEntity.entityId`) rather than re-querying the list endpoint. Takes the same `fields`/`from`/`to` params as the list endpoint (same lookback-window caveat below applies), plus the same relationship-field throttling risk on large requests. |

### entitySelector grammar (comma = AND; exactly one root criterion required)
```
type("TYPE")                         # required unless entityId() is used instead — exactly one
entityId("ID1","ID2")                # alternative root criterion; all IDs must be same type
entityName("frag")                   # CONTAINS match (this is the bare/default form — NOT exact)
entityName.equals("Name")            # EQUALS, case-insensitive
caseSensitive(entityName.equals("Name"))  # EQUALS, case-sensitive (wraps any name criterion)
entityName.startsWith("frag")        # BEGINS WITH
entityName.in("Name1","Name2")       # EQUALS, multiple values (OR)
tag("[context]key:value" | "key:value" | "value")   # escape literal ':' in key/value with '\'
mzId("123") / mzName("name")         # management zone, multi-value = OR
healthState("HEALTHY"|"UNHEALTHY")
firstSeenTms.<lte|lt|gte|gt>(<time>)
<attribute>("v1","v2") / <attribute>.exists()   # names come from entityTypes → properties[].id; value comparison IS case-sensitive, attribute name is not
fromRelationships.<relName>(<nested-entitySelector>)
toRelationships.<relName>(<nested-entitySelector>)
deletedEntities.include() / deletedEntities.exclude()   # deleted entities are excluded by default; only applies to HTTP_CHECK, SYNTHETIC_TEST, EXTERNAL_SYNTHETIC_TEST, MULTIPROTOCOL_MONITOR, APPLICATION, MOBILE_APPLICATION, CUSTOM_APPLICATION, DCRUM_APPLICATION, CUSTOM_DEVICE
not(<criterion>)                     # inverts any criterion except type()
```
- Max selector length **2,000 chars**; max **10,000 entities** matched per query (see §0 cheat sheet — this is *not* the same limit as Metrics' 5,000); **exactly one** type()/entityId() root criterion per query (never both, never zero).
- `entityName("x")` with no suffix is a **substring/CONTAINS** match — there is no `entityName.contains()` variant; that's the default behavior of the bare form. Use `.equals()` for exact (case-insensitive by default — wrap in `caseSensitive(...)` for exact case), `.startsWith()` for prefix, `.in("a","b")` for multi-value exact match.
- Tag values, mzName values, and healthState comparisons are case-sensitive; entity/attribute-name comparisons are not (unless wrapped in `caseSensitive(...)`).
- Relationship names are **tenant/type-specific — and their casing is not guaranteed to be camelCase.** Always confirm the exact string via `entityTypes`/`entityTypes/{type}` for this tenant before using it in a selector; don't assume a name from documentation examples, since Dynatrace's own docs show both `isDiskOf`/`isInstanceOf`-style camelCase and `IS_DISK_OF`/`RUNS_ON_RESOURCE`-style upper-snake-case in different reference examples. A relationship-name mismatch fails silently (zero results, no error) — if a relationship query returns nothing, re-check the exact `id` string from `entityTypes` rather than assuming the relationship doesn't exist.

### `from` / `to` — a common cause of "entity not found"
- **Default is `now-3d`**, not `now-2h` like Problems/Events/Metrics. An entity that hasn't reported/been observed within the queried window **will not appear**, even if it still exists in Smartscape. If a lookup for a known entity comes back empty, widen `from` (e.g. `now-30d` or further) before concluding it doesn't exist.
- Same format options as Problems/Events: epoch-ms, ISO-8601, or relative `now-NU[/A]` (`m h d w M y`).

### `fields` — nothing but ID/name is returned by default
- Only `entityId` and `displayName` are always included. **Everything else — `type`, `properties`, `tags`, `managementZones`, `fromRelationships`, `toRelationships`, `icon`, `firstSeenTms`, `lastSeenTms` — must be explicitly requested**, prefixed with `+`: `fields=+type,+tags,+properties,+managementZones,+fromRelationships,+toRelationships`.
- `properties` sub-fields use dotted form: `properties.BITNESS`, `properties.serviceTechnologyTypes`, etc. — get the valid property IDs per type from `entityTypes`.
- Request only what's needed for the current question — **large relationship-field requests can be throttled**, so don't reflexively request `+fromRelationships,+toRelationships` on a broad multi-entity list query; reserve that for a targeted `entityId(...)` lookup once you've narrowed to the entity(ies) that matter.

### `sort`
Only `name` is sortable: `sort=name`/`sort=+name` (ascending, default) or `sort=-name` (descending). No other sort keys exist on this endpoint.

### Pagination
`pageSize` (default 50) + `nextPageKey`.

### Response shape
`entities[]`, each with `entityId`, `displayName`, and whatever was requested via `fields`: `type`, `firstSeenTms`, `lastSeenTms`, `properties{}`, `tags[]` (`context`, `key`, `value`, `stringRepresentation`, `source`), `managementZones[]`, `fromRelationships{<relName>: [{id, type}, ...]}`, `toRelationships{<relName>: [{id, type}, ...]}`. This **is** the Smartscape graph — there is no separate "topology" endpoint. `fromRelationships`/`toRelationships` are objects keyed by relationship name, each holding an array of `{id, type}` entity stubs — not a flat list, so when parsing, iterate the keys.

### Patterns

**Discover relationship/property names for a type before building a query (do this once, not per-query, if unsure):**
```
GET /api/v2/entityTypes/SERVICE
```

**Resolve full dependency chain outward from a known entity (preferred over the list endpoint when you already have the ID):**
```
GET /api/v2/entities/SERVICE-1125C375A15647A?fields=+tags,+properties,+managementZones,+fromRelationships,+toRelationships
```
Then walk each relationship's `{id, type}` stubs one hop at a time (e.g. `toRelationships.runsOnHost` → `HOST`, then that host's `toRelationships.isDiskOf` → `DISK`) rather than trying to encode the whole multi-hop chain in one nested selector — it's more reliable and each hop's response tells you what relationship names actually exist to go further.

**Resolve full dependency chain via list query, scoped by tag:**
```
GET /api/v2/entities?entitySelector=type("SERVICE"),tag("app:X")&fields=+fromRelationships,+toRelationships&from=now-3d
```

**Find hosts running processes belonging to a tagged service (multi-hop nested selector — works, but verify relationship names first via entityTypes):**
```
GET /api/v2/entities?entitySelector=type("HOST"),toRelationships.runsOnHost(type("PROCESS_GROUP_INSTANCE"),fromRelationships.isProcessOf(type("SERVICE"),tag("app:X")))
```

**Exact-name lookup instead of substring:**
```
GET /api/v2/entities?entitySelector=type("HOST"),entityName.equals("prod-web-01")
```

---

## 2. Problems API v2 — incidents & root cause

**Managed base URL pattern (note: NOT the SaaS `.live.dynatrace.com` host):**
```
https://{your-activegate-domain}:9999/e/{your-environment-id}/api/v2/problems           (list)
https://{your-activegate-domain}:9999/e/{your-environment-id}/api/v2/problems/{problemId} (detail)
```
Auth: API token with `problems.read` scope (or PAT with `environment:roles:viewer`).

### 2.1 Query parameters

**`problemSelector`** (comma-separated = AND, values inside one criterion = OR, all values quoted):
- `status("OPEN"|"CLOSED")` — only one value allowed
- `severityLevel("AVAILABILITY","ERROR","PERFORMANCE","RESOURCE_CONTENTION","CUSTOM_ALERT","MONITORING_UNAVAILABLE","INFO")`
- `impactLevel("APPLICATION"|"SERVICES"|"INFRASTRUCTURE"|"ENVIRONMENT")`
- `rootCauseEntity("id-1","id-2")` — jump straight to problems whose root cause is a known entity
- `managementZoneIds("mzId-1",...)` / `managementZones("name-1",...)`
- `impactedEntities("id-1",...)` / `affectedEntities("id-1",...)` / `affectedEntityTypes("HOST",...)`
- `problemId("id-1",...)` / `displayId("P-123",...)`
- `problemFilterIds(...)` / `problemFilterNames(...)` / `problemFilterNames.equals(...)` (alerting profile)
- `entityTags("[context]key:value","key:value","value")`
- `underMaintenance(true|false)`
- `text("value")` — searches title, event titles, displayId, affected/impacted entity IDs. Case-insensitive, partial match, relevance-scored. **Max 30 characters.** Escape `"` and `~` with `~`. Always pair with `sort=-relevance` when used, or results won't be ranked by match quality.

Max `problemSelector` length: **1,000 characters**.

**`entitySelector`** — same grammar as the entity endpoints (§1): `type()`, `entityId()`, `tag()`, `mzId()`, `mzName()`, `entityName.equals/.startsWith/.in()`, `healthState()`, `firstSeenTms.<lte|lt|gte|gt>()`, arbitrary `<attribute>()`/`<attribute>.exists()`, `fromRelationships.<name>()`/`toRelationships.<name>()`, `not(...)`. Max 2,000 chars, max 10,000 matched entities.

**`from` / `to`** — `now-2h` default if omitted. Accepts epoch-ms, ISO-8601, or relative (`now-NU/A`, units `m h d w M y`). A problem is returned if **either** its start or end falls in the window — for a problem that started before your window, widen `from` or you'll miss its full evidence timeline.

**`fields`** (list endpoint AND detail endpoint both need this **on every call/page** — it is not sticky across `nextPageKey` pagination):
- `evidenceDetails` — the actual root-cause evidence list. **This is the field that matters for RCA and it is easy to forget.**
- `impactAnalysis` — blast radius (which apps/services/mobile clients are impacted, estimated affected users)
- `recentComments` — human annotations already on the problem (check this before re-deriving something an engineer already diagnosed)

**`sort`**: `status`, `startTime`, `relevance` (only with `text()`), each with `+`/`-` prefix, comma-chainable.

### 2.2 Response fields that drive the RCA narrative

`problemId`, `displayId`, `title`, `status`, `severityLevel`, `impactLevel`, `startTime`/`endTime` (`endTime:-1` = still open), `rootCauseEntity` (**can legitimately be `null`** — not every problem has one Davis-identified root-cause entity; fall back to evidence analysis in that case), `affectedEntities[]` vs `impactedEntities[]` (affected = topologically touched; impacted = actually degraded/felt the symptom — don't conflate them in your narrative), `managementZones[]`, `linkedProblemInfo` (correlated parent/child problem — always check this and pull the linked problem too), `entityTags[]`, `k8s.cluster.name/uid`, `k8s.namespace.name`.

### 2.3 Evidence types — how to actually read `evidenceDetails.details[]`

Every evidence item has `evidenceType`, `displayName`, `entity`, `groupingEntity`, `startTime`, and **`rootCauseRelevant` (boolean)**. **Always filter/sort on `rootCauseRelevant: true` first** and build the primary narrative from those; treat `rootCauseRelevant: false` items as contributing/correlated context only, not causal claims. Each type adds different fields — interpret them accordingly:

| evidenceType | extra fields | how to use it in RCA |
|---|---|---|
| `METRIC` | `metricId`, `unit`, `valueBeforeChangePoint`, `valueAfterChangePoint` | Quantify the anomaly: state the metric, and the before→after delta with unit (e.g. "CPU saturation on `host-x` jumped from 40% to 97%"). This is usually the strongest quantitative RCA evidence. |
| `TRANSACTIONAL` | `unit`, `valueBeforeChangePoint`, `valueAfterChangePoint`, `endTime` | Same as METRIC but scoped to a transaction/service-call metric (e.g. response time, failure rate) — use for service-level degradation narratives. |
| `EVENT` | `eventId`, `eventType`, `data` (full `Event` object: `title`, `status`, `startTime`/`endTime`, `entityId`, `properties[]`, `correlationId`, `suppressAlert`, `suppressProblem`, `underMaintenance`, `frequentEvent`) | Look at `data.title` and `data.properties` for what actually fired (deployment event, process restart, config change, custom event). If `data.underMaintenance` is true or `frequentEvent` is true, downweight it as a cause. |
| `AVAILABILITY_EVIDENCE` | `endTime` | An entity went unavailable/unreachable during the window — check whether its unavailability window brackets the problem start (likely upstream cause) or trails it (likely downstream casualty). |
| `MAINTENANCE_WINDOW` | `maintenanceWindowConfigId`, `endTime` | The problem occurred during planned maintenance — flag this explicitly, since it changes the RCA conclusion from "incident" to "expected/suppressible." |

Cross-reference `entity` vs `groupingEntity` on each evidence item: `entity` is the specific object where the signal occurred; `groupingEntity` is what Davis grouped it under (often the same as `rootCauseEntity` or one level up in topology) — use `groupingEntity` to explain *why* Davis attributed the evidence where it did.

### 2.4 Impact analysis — quantify the blast radius, don't just list it

`impactAnalysis.impacts[]` items share `impactType`, `impactedEntity`, `estimatedAffectedUsers`, plus type-specific fields:
- `SERVICE` → also `numberOfPotentiallyAffectedServiceCalls`
- `APPLICATION` / `CUSTOM_APPLICATION` / `MOBILE` → `estimatedAffectedUsers` is the headline number

Always state `estimatedAffectedUsers` and (for services) `numberOfPotentiallyAffectedServiceCalls` explicitly in the RCA summary — a root cause without quantified impact is half an answer.

### 2.5 Deep RCA workflow (use this every time, not just a single list call)

1. **Scope the query.** Prefer `problemSelector=status("OPEN")` + `entitySelector=tag(...)`/`mzName(...)` for "what's broken" questions; use `problemSelector=text("keyword")&sort=-relevance` for "is there a problem related to X" questions; use `problemSelector=rootCauseEntity("id")` if the user already named a suspect entity.
2. **List call** with `fields=+evidenceDetails,+impactAnalysis,+recentComments` to get everything in one shot for problems in scope.
3. **If the list call truncates evidence or you need the single clearest picture of one problem**, follow up with the **detail** call (`GET /problems/{problemId}?fields=evidenceDetails,impactAnalysis,recentComments`) for that specific `problemId` — the detail endpoint is not summarized/paginated the way list-embedded evidence can be.
4. **Read `recentComments` first** — don't re-derive a root cause an engineer already documented; surface it and add supporting evidence instead.
5. **Filter `evidenceDetails.details[]` to `rootCauseRelevant:true`**, sort by `startTime` ascending, and identify the earliest root-cause-relevant item — that's usually the trigger. Interpret it per the table in §2.3.
6. **Resolve `rootCauseEntity.entityId`** (or, if null, the `entity`/`groupingEntity` of the earliest root-cause evidence) via the Monitored Entities API (§1) — pull its `fromRelationships`/`toRelationships` to show the dependency chain (e.g. process → process group → host → management zone) so the narrative explains *how* the failure propagated, not just *where* it started.
7. **Check `linkedProblemInfo`** — if set, fetch that problem too; Davis may have split one real incident into correlated problems.
8. **State impact** using §2.4 numbers.
9. **Synthesize**: one-paragraph root cause narrative (what changed, on what entity, evidenced by what metric/event delta) → propagation chain (via entity relationships) → quantified impact → any caveats (`rootCauseEntity` was null and this is inferred; problem occurred under maintenance; evidence marked non-root-cause was excluded).

### 2.6 Common causes of shallow answers — check these first

- Forgetting `fields=` on the specific call (it must be repeated per request/page, including on `nextPageKey` follow-ups).
- Reading `evidenceDetails` without filtering `rootCauseRelevant:true`, so the narrative gets diluted with correlated noise.
- Treating a `null` `rootCauseEntity` as "no data" instead of falling back to earliest root-cause-relevant evidence.
- Never calling the **detail** endpoint for the specific problem the user cares about — the list call is for triage/scoping, the detail call is for the actual RCA.
- Not resolving `rootCauseEntity`/evidence entities through §1's entity relationships, so the answer names an entity but never explains the propagation path.
- Ignoring `recentComments` and `linkedProblemInfo`, both of which often contain the fastest path to a correct answer.

**Pattern — "what's broken in prod right now, with root cause":**
```
GET /api/v2/problems?problemSelector=status("OPEN")&entitySelector=tag("env:production")&from=now-2h&fields=+evidenceDetails,+impactAnalysis,+recentComments
```
Then for the specific problem(s) surfaced:
```
GET /api/v2/problems/{problemId}?fields=evidenceDetails,impactAnalysis,recentComments
```
Then resolve `rootCauseEntity.entityId` (or the earliest root-cause-relevant evidence entity) via §1 for its full relationship chain. This 2–3 call sequence is the reliable path to a complete, evidenced root-cause narrative — a single list call with raw JSON is not.

---

## 3. Metrics API v2 — full reference (Dynatrace Managed)

Gives complete, self-contained knowledge of the Metrics v2 API surface (catalog, metadata, query),
every transformation and selector option, and a resolution strategy for this environment's **custom /
calculated metrics** so that short, low-context user questions ("show me all calls from Sp t1 to
databases", "show me all clients response codes of RESTful") map to the correct `metricSelector`
without the user having to spell out the exact metric key.

### 3.1 Base URLs (Dynatrace Managed)

```
Cluster (direct):     https://{your-domain}/e/{your-environment-id}/api/v2/...
Via ActiveGate:        https://{your-activegate-domain}:9999/e/{your-environment-id}/api/v2/...
```

All three Metrics v2 endpoints hang off this base:

| Purpose                              | Method | Path                          |
|---------------------------------------|--------|--------------------------------|
| Metric catalog (list/search metrics) | GET    | `/api/v2/metrics`             |
| Metric metadata (one metric)         | GET    | `/api/v2/metrics/{metricId}`  |
| Metric data points (time series)     | GET    | `/api/v2/metrics/query`       |

Auth: `Authorization: Api-Token {token}` with the `metrics.read` scope.

### 3.2 Metric catalog — `GET /api/v2/metrics`

Use this to **discover** metrics before querying them — this is the primary tool for turning a vague
user question into a concrete `metricSelector`, especially for custom/calculated metrics whose keys
are not memorable.

| Parameter          | Notes |
|--------------------|-------|
| `metricSelector`   | Same selector syntax as query. Supports trailing wildcard: `builtin:host.*`, `builtin:*`, `calc:*`, `ext:*`. Only `aggregation`, `merge`, `parents`, `splitBy` transforms are honored here (others are query-only). |
| `text`             | **Free-text search** — matches metric key, `displayName`, or `description`. This is the right tool when the user gives you a vague name and you don't want to grep a static list. Example: `text=restful` or `text=database%20calls`. |
| `metadataSelector` | Filter by metadata: `unit("Percent")`, `tags("tag1","tag2")`, `dimensionKey("service_method")`, `exported("true")`, and critically **`custom("true")`** — returns only user-defined metrics (no namespace, or `ext:`, `calc:`, `func:`, `appmon:`). Combine with `,` for AND. |
| `fields`           | Which metadata fields to return. `metricId` always included. Add `+displayName,+description,+unit,+entityType,+dimensionDefinitions,+aggregationTypes,+transformations,+tags` as needed. Prefix with `+` to add, `-` to remove from the default set. |
| `writtenSince` / `writtenSinceMode` | Only return metrics that have (or have not) written data points since a given time — useful to filter out dead/retired custom metrics. |
| `pageSize` (max 500), `nextPageKey` | Pagination. |

**Discovery pattern for a vague ask** (preferred over guessing a key from memory):

```
GET /api/v2/metrics?text=restful&metadataSelector=custom("true")&fields=+displayName,+description,+entityType
GET /api/v2/metrics?text=database%20calls&metadataSelector=custom("true")
GET /api/v2/metrics?metricSelector=calc:service._custommetric*&fields=+displayName
```

### 3.3 Metric metadata — `GET /api/v2/metrics/{metricId}`

Returns one metric's full descriptor: `displayName`, `description`, `unit`, `entityType`,
`aggregationTypes`, `defaultAggregation`, `transformations`, `dimensionDefinitions`,
`metricSelector` (for `func:` metrics — shows the underlying expression), `scalar`, etc.

- `builtin:host.cpu.idle` and `builtin:host.cpu.usage` share a parent, so their combined selector is
  `builtin:host.cpu.(idle,usage)`.
- **Always resolve the descriptor before querying an unfamiliar metric** to confirm: its real
  `displayName` (the human label the metric was created with), which `entityType` it scopes to (so you
  pick a valid `entitySelector`), its `dimensionDefinitions` (so you know what a `:filter`/`:splitBy`
  can target), and its `defaultAggregation` (so you don't need to guess whether a `count` metric
  defaults to `sum` vs `value`).

### 3.4 Metric selector syntax

```
<namespace>:<metric>[:<transform1>[(<args>)]][:<transform2>[(<args>)]]...
```

- A selector must contain at least one metric key; up to **10 metrics per query**, combined with commas
  or the parenthesized-suffix shorthand: `builtin:host.cpu.(usage,idle)` = `builtin:host.cpu.usage,builtin:host.cpu.idle`.
- Wildcards (`builtin:host.*`, `builtin:*`) work on the **catalog** endpoint, not on `/query`.
- If a metric key contains special characters (spaces, colons in the *name* part, etc.) quote it:
  `"ext:selfmonitoring.jmx.Agents: Type ~"APACHE~""`. Escape embedded `"` and `~` with a tilde (`~`).
- Transformations chain left-to-right; each operates on the output of the previous one.

### Full transformation reference

| Transform | Syntax | What it does |
|---|---|---|
| **Aggregation** | `:auto` `:avg` `:count` `:histogram` `:max` `:min` `:percentile(N)` `:sum` `:value` | Time-slot aggregation. `:auto` = the metric's `defaultAggregation`. Must precede several other transforms (delta, rate, rollup, unit transforms). |
| **default** | `:default(N[,always])` | Replaces `null` values with `N`. `always` also fills an entirely empty result (only valid right after an empty `:splitBy()`). |
| **delta** | `:delta` | Each point becomes the difference from the previous point (0 if negative); first point dropped. Needs an aggregation first. |
| **filter** | `:filter(<cond>,...)` | Filters by a **secondary** dimension (entitySelector only reaches the primary/first dimension). All listed conditions must match (implicit AND unless wrapped in `or()`). Conditions: `prefix()`, `suffix()`, `contains()`, `eq()`, `ne()`, `in("<dim>",entitySelector("<sel>"))`, `existsKey()`, `remainder()`, `series(<agg>,<op>(<val>))`. Combine with `and()`, `or()`, `not()`. Escape `"`/`~` in nested values with `~`. |
| **fold** | `:fold[(<agg>)]` | Collapses the whole timeframe into one data point. |
| **last / lastReal** | `:last[(<agg>)]` / `:lastReal[(<agg>)]` | Most recent point. `last` stamps all tuples with the same (latest overall) timestamp; `lastReal` keeps each tuple's own actual last timestamp. |
| **limit** | `:limit(N)` | Keep only the first N tuples (pair with `:sort` first). |
| **merge** | `:merge("<dim>",...)` | **Removes** named dimensions, merging series that become identical; recalculates per the active aggregation. Any aggregation is allowed here, even ones the base metric doesn't natively support. |
| **names** | `:names` | Adds the human-readable name of each ENTITY dimension alongside its ID. |
| **parents** | `:parents` | Adds the parent entity of a dimension, e.g. SERVICE_METHOD→SERVICE, PROCESS_GROUP_INSTANCE→HOST, SERVICE_INSTANCE→SERVICE, DISK→HOST, NETWORK_INTERFACE→HOST, SYNTHETIC_TEST_STEP→SYNTHETIC_TEST, HTTP_CHECK_STEP→HTTP_CHECK, APPLICATION_METHOD→APPLICATION. |
| **partition** | `:partition("<newDim>",value("<label>",<criterion>)\|dimension("<label>",<criterion>),...,otherwise("<label>"))` | Buckets data points of one series into several new labeled series (e.g. fast/normal/slow response-time buckets) without discarding data. |
| **rate** | `:rate(<unit>)` (`s m h d w M y`, optionally with an integer factor e.g. `5m`) | Converts a count metric into a rate (default: per-minute). Needs `VALUE` aggregation first; usable once per chain. |
| **rollup** | `:rollup(<agg>,<window>)` | Smooths spikes using a trailing window (max 60 min window, max 2-week lookback). Needs an aggregation first. |
| **smooth** | `:smooth(skipfirst)` | Nulls out the first point right after a data gap. |
| **sort** | `:sort(dimension("<dim>",asc\|desc[,lexical\|natural]))` or `:sort(value(<agg>,asc\|desc))` | Orders tuples; multiple keys = tie-break chain. |
| **splitBy** | `:splitBy("<dim>",...)` | **Keeps** the named dimensions, merges everything else (inverse of `merge`). Empty `splitBy()` collapses all dimensions into one series. |
| **timeshift** | `:timeshift(<Ns>\|<Nm>\|<Nh>\|<Nd>\|<Nw>)` | Shifts the query window (± up to 5 years) and re-stamps results onto the original timeframe — handy for day-over-day/timezone comparisons. |
| **setUnit** | `:setUnit(<unit>)` | Relabels the unit in metadata only — does **not** convert values. |
| **toUnit** | `:toUnit(<sourceUnit>,<targetUnit>)` | Actually converts data point values between compatible units. Needs an aggregation first. |

### Space vs. time aggregation, in one line
Aggregation transforms (`:avg`, `:sum`, ...) control **time**-axis aggregation (how points in one time
slot combine). `:splitBy()` / `:merge()` control **space**-axis aggregation (how many series/dimension
tuples you get back). You'll typically use both, e.g.:

```
builtin:kubernetes.pods:filter(eq("k8s.cluster.name","preproduction")):splitBy("dt.entity.cloud_application"):max
```

### 3.5 Entity selector (`entitySelector` query param — scopes the *primary* dimension only)

```
entitySelector=type(HOST),tag("env:production")
```

Required: `type("TYPE")` or `entityId("ID"[,"ID2",...])` (all IDs must share one type). Optional,
comma-separated (comma = AND, multiple values inside one criterion = OR):

- `tag("value")` — `[context]key:value`, `key:value`, or bare `value`; escape literal `:` with `\`.
- `mzId(123)` / `mzName("value")`
- `entityName.equals("value")` (case-insensitive), `.startsWith("value")`, `.in("v1","v2")`;
  wrap in `caseSensitive(...)` to force case-sensitive matching.
- `healthState("HEALTHY"|"UNHEALTHY")`
- `firstSeenTms.<lte|lt|gte|gt>(<time>)`
- `<attribute>("v1","v2")` / `<attribute>.exists()` — arbitrary entity properties (discover per entity
  type via `GET /entityTypes/{type}`).
- `fromRelationships.<name>(<nested selector>)` / `toRelationships.<name>(<nested selector>)`
- `not(<criterion>)` — negates anything except `type`.

Max string length 2,000 chars; **max 5,000 matched entities per `entitySelector` per query** (this is
the Metrics API's own limit — it's lower than the 10,000 allowed on the Entities/Events APIs; split
by an additional tag/mz/type filter rather than looping calls if you'd exceed it.

### Filtering a *secondary* dimension (e.g. one specific service inside a service-method metric)
`entitySelector` only reaches the first/primary entity dimension. To scope a secondary dimension,
nest an entity selector inside a `:filter(in(...))` on the metric itself:

```
metricSelector=builtin:service.keyRequest.errors.fourxx.rate:filter(
  in("dt.entity.service_method",
     entitySelector("type(SERVICE_METHOD),fromRelationship.isServiceMethodOfService(type(SERVICE),entityId(\"SERVICE-XXXX\"))"))
)
```
Escape embedded quotes inside the nested selector with `~` (per metric-selector syntax), e.g.
`entitySelector("type(~"HOST~"),tag(~"easyTravel~")")`.

Alternative for a **primary** entity dimension that's the same as what `entitySelector` would scope
(e.g. filtering hosts on a host metric): you can equivalently write it as a `:filter` on the metric
directly and skip `entitySelector` — the difference is representational: `entitySelector` alone
returns the raw point list, while folding the same condition into `:filter(...):fold` returns one
aggregated point per series.

### 3.6 Management zone selector (`mzSelector`)

```
mzSelector=mzName("name-1","name-2"),mzId(1234)
```
Same OR-within-criterion / AND-across-criteria logic as `entitySelector`.

### 3.7 Time parameters

| Param | Format | Default |
|---|---|---|
| `from` / `to` | UTC ms timestamp · ISO `2021-01-25T05:57:01.123+01:00` (space allowed instead of `T`, TZ optional→UTC) · relative `now-NU[/A]` where `N`=amount, `U`∈`m h d w M y`, `A`=alignment (rounds smaller units to the nearest past boundary, e.g. `now-1y/w`) | `from`: `now-2h` · `to`: now |
| `resolution` | A point-count (e.g. `120`, the default) **or** a timespan-with-unit (`5m`,`1h`,`3w`, units `m h d w M q y`) **or** `Inf` for one aggregate point. Per-metric-index override for multi-metric selectors: `resolution=0:Inf,1:10`. Finest resolution is 1 minute. | 120 data points |

**Always set `resolution` explicitly for chart-style / trend answers** to avoid huge point counts;
use `resolution=Inf` when the user just wants a single current/aggregate number.

### 3.8 Query limits (`/api/v2/metrics/query`)

- Up to **10 metrics** per query (comma-separated or parenthesized-suffix combined).
- **5,000 entities max** per `entitySelector` per query.
- **100,000 tuples** max in a result (extra ones dropped, ignoring `:sort`) — add filters or split the
  query (by sub-zone, type, or time window) instead of looping unnecessarily.
- **10,080 data points per tuple**, **20,000,000 total data points** per query.

### 3.9 Response shape

```
result[].data[] → { dimensions[], dimensionMap{}, timestamps[], values[] }
```
one entry per matched metric/entity/dimension combination. `dimensions`/`dimensionMap` will be `null`
for the **remainder** bucket (everything beyond the top-N dimension tuples Dynatrace keeps) — that's
different from a dimension key being *absent* from `dimensionMap` entirely (a literal null value case).
`Accept: text/csv; header=present` gives a flat CSV instead of nested JSON if that's easier to render.

### 3.10 Worked patterns

```
# CPU across all production hosts, right now, chart-ready
GET /api/v2/metrics/query?metricSelector=builtin:host.cpu.usage&entitySelector=type(HOST),tag("env:production")&from=now-30m&resolution=5m

# Single current aggregate number (not a chart)
GET /api/v2/metrics/query?metricSelector=builtin:host.cpu.usage:avg&entitySelector=type(HOST),tag("env:production")&resolution=Inf&from=now-15m

# Top 10 hosts by max CPU, last 24h
GET /api/v2/metrics/query?metricSelector=builtin:host.cpu.usage:sort(value(max,descending)):limit(10)&from=now-24h&resolution=1h

# One specific custom calculated service metric
GET /api/v2/metrics/query?metricSelector=calc:service._custommetric__numberofcallstodatabses__system_services_3_pc1_&from=now-6h&resolution=15m
```

---

## 3.A Custom / calculated metric name resolution (this environment)

This environment ships a large, org-specific metric catalog. Most of
it is standard Dynatrace `builtin:*`. But **custom/calculated metrics are the ones users will ask
about in plain business language**, so this section defines how to go from a short, low-context
question to the right `metricSelector` with high confidence, and what to do when it's ambiguous.

### 3.A.1 What's actually in this environment (namespace inventory)

| Namespace | Count | What it is |
|---|---|---|
| `builtin:*` | 2,310 | Dynatrace's standard metrics. Biggest sub-groups here: `tech.*` (1,202 — process/technology metrics: JVM, .NET, DBs, message queues, etc.), `cloud.*` (435), `synthetic.*` (164), `apps.*` (131 — RUM/mobile), `host.*` (101), `service.*` (95), `billing.*` (95), `kubernetes.*` (44), `containers.*` (19), `security.*` (10), plus small groups (`process`, `pgi`, `queue`, `span_*`). |
| `calc:service.*` | 406 | **User-defined calculated service metrics**, built in the UI under *Settings → Metrics → Calculated metrics → Services*. Of these, **111** carry the literal token `_custommetric__` in their key — these are the org's hand-named business metrics (call counts, DB call counts/time, response-time buckets, TPS, response-code breakdowns, MI-pool/active-client gauges, mobile activity, 3-DS/ACS flows, etc.). The remaining ~295 `calc:service.*` entries (no `_custommetric__` token) are other calculated service metrics, mostly response-code / duration-bucket breakdowns per client group (e.g. `calc:service._c_admin__responsecodetrends_`, `calc:service._android__1.x_allresponsecodes`). 
| `func:com.dynatrace.extension.*` | 32 | Vendor Extension 2.0 mtrics surfaced through `func:` (e.g. F5 BIG-IP, Palo Alto). |
| `func:tomcat.*` / `func:memcached.*` | 8 / 1 | Extension-sourced Tomcat/memcached technology metrics. |
| `com.dynatrace.extension.*` (no `func:` prefix) | 247 | Extension 2.0 ingested metrics (disk-devices, etc.) — process/host-scoped technology metrics from installed extensions. |
| `dsfm:*` | 264 | Dynatrace **self-monitoring** metrics (platform health, not customer application health): `server.*` (87 — cluster/server internals), `active_gate.*` (69), `datasource.*` (36), `extension.*` (31), `synthetic.*` (15), `oneagent.*` (6), `storage.*` (5), `ingest.*` (4), `billing.*`/`cluster.*`/`spans.*` (3 each), `atm.*`/`security.*` (1 each). Rarely what an end user is asking about — surface these only for platform/health questions. |
| `ext:tech.*` | 75 | Legacy (Extensions 1.0 / plugin.json) technology metrics, e.g. `ext:tech.Informix.*`. |
| `custom.*` | 22 | Legacy ingested/custom timeseries (pre-Metrics-v2 style), e.g. `custom.all.restful.clients.decline.response.codes`, `custom.db.query.*`. **Distinct from `calc:service._custommetric__*`** — same-sounding names can refer to two different metrics; see 3.A.4. |
| `kafka.*` / `mysql.*` | 64 / 32 | Extension-sourced Kafka and MySQL technology metrics. |
| misc singletons | ~10 | `jre.version*`, `server.cpu.temperature`, `kubelet_volume_stats_*`, `tmp` |

### 3.A.2 How `calc:service._custommetric__*` keys are built (decoding heuristic)

These keys come from the **display name the metric was given when created** in the Dynatrace UI,
mechanically normalized: lower-cased, spaces and punctuation collapsed to underscores, and a `__`
frequently marking the boundary between *what is measured* and *which service it's measured on*.
General shape:

```
calc:service._custommetric__<what>__<service-or-scope>_
```

Examples from this environment:

<Give Your Custom Metric instructions>

When the user says something like *"S3 t1"* any any other incomplete statement— treat it as a
pointer into this vocabulary, not as literal text to grep. Normalize their phrase (lowercase, strip
punctuation/spaces) and match it against the scope tokens above and against `displayName`/`text`
search results (3.2), rather than requiring an exact key match.

```

### 3.A.5 General principle

Don't require the user to supply full context on every turn. Once an entity nickname or metric concept
has been resolved once in the conversation, reuse that mapping for follow-ups ("now show the same for
PC2", "what about RESTful's error rate instead of response codes") without re-deriving it from scratch
— but always re-verify via 3.3/3.4 before switching to a materially different metric or entity, since a
plausible-looking key is not the same as a confirmed one.

---

## 4. Logs API v2 (Log Classic)

**Base (Managed):** `/api/v2/logs/search`, `/api/v2/logs/aggregate`
(`/api/v2/logs/export` and `/api/v2/logs/ingest` also exist but are for
bulk export / write, not investigation reads).

- `query`: DQL-like filter string, e.g.
  `dt.entity.host = "HOST-XXXX"`, `loglevel = "ERROR"`,
  `content CONTAINS "OutOfMemory"`. Combine with `AND`/`OR`.
- `entitySelector`: scope to the topology subset from §1 instead of a raw
  text search across the whole tenant:
  ```
  entitySelector=type(PROCESS_GROUP_INSTANCE),fromRelationships.isProcessOf(type(HOST),tag("env:production"))
  ```
- `from` / `to`: **required** — there is no implicit default for this API.
- `/logs/search`: returns individual matching log records
  (`results[]`, paged via `nextSliceKey`) — use for "show me the error
  logs around this timestamp."
- `/logs/aggregate`: returns counts/grouped stats
  (`groupBy=log.source`, `timeBuckets=N`) — use for "how many ERROR logs
  per host in the last hour" instead of pulling raw records and counting
  client-side.
- Retention up to **35 days**, tenant-configurable — confirm this cluster's
  actual setting (§11) rather than assuming the maximum; state the caveat
  if a request implies an older window.

**Pattern — root-cause log pull for a problem's root-cause entity:**
```
GET /api/v2/logs/search?query=loglevel="ERROR"&entitySelector=entityId("<rootCauseEntity.id>")&from=<problem.startTime>&to=<problem.endTime or now>
```

---

## 5. Events API v2 — full reference (Dynatrace Managed)

`entitySelector` is **not** nested inside `eventSelector` — it is its own top-level query parameter,
exactly parallel to how it works on the Metrics API. `eventSelector=entitySelector(...)` is invalid and
will fail to parse. The correct pattern is
`eventSelector=<criteria>&entitySelector=<criteria>&from=...&to=...`, e.g.:
```
GET /api/v2/events?eventSelector=eventType("AVAILABILITY_EVENT"),status("OPEN")&entitySelector=type("HOST"),tag("env:production")&from=now-2h
```

### 5.1 Base URLs & endpoints (Managed)
```
Cluster (direct):    https://{your-domain}/e/{your-environment-id}/api/v2/...
Via ActiveGate:       https://{your-activegate-domain}:9999/e/{your-environment-id}/api/v2/...
```

| Purpose | Method | Path | Auth scope |
|---|---|---|---|
| List events | GET | `/api/v2/events` | `events.read` |
| Get one event | GET | `/api/v2/events/{eventId}` | `events.read` |
| Ingest a custom event | POST | `/api/v2/events/ingest` | `events.ingest` |
| List all event types | GET | `/api/v2/eventTypes` | `events.read` |
| List all event properties (registry) | GET | `/api/v2/eventProperties` | `events.read` |
| Get one event property | GET | `/api/v2/eventProperties/{key}` | `events.read` |

### 5.2 GET list events — `/api/v2/events`

| Parameter | Notes |
|---|---|
| `eventSelector` | See 5.3 below. Optional — omit to match all events. |
| `entitySelector` | Same grammar as the Metrics API entity selector (5.4). Optional — omit for environment-wide scope. Up to 10,000 entities may be matched (higher than the Metrics API's 5,000). |
| `from` / `to` | Same formats as Metrics API: UTC ms, ISO-8601 (`2021-01-25T05:57:01.123+01:00`, space allowed instead of `T`, no TZ→UTC), or relative `now-NU[/A]` (`m h d w M y`). Default `from=now-2h`, default `to=now`. |
| `pageSize` | Max 1000 (higher than most other v2 APIs), default 100. |
| `nextPageKey` | Pagination cursor from the previous response's `nextPageKey`. When set, every other query parameter must be omitted. |

### 5.3 `eventSelector` criteria (comma-separated = AND; multiple values inside one criterion = OR)

| Criterion | Syntax | Notes |
|---|---|---|
| Event ID | `eventId("id-1","id-2")` | |
| Related entity ID | `entityId("id-1","id-2")` | Simple entity-ID match — for richer topology filtering (tags, mz, relationships) use the separate `entitySelector` param instead (5.4). |
| Status | `status("OPEN")` or `status("CLOSED")` | Exactly one value only. |
| Management zone ID | `managementZoneId("123","321")` | |
| Event type | `eventType("EVENT_TYPE")` | Exactly one value only (see 5.6 for the type catalog / how to look it up). |
| Correlation ID | `correlationId("id-1","id-2")` | Ties together events from the same source/ingest batch. |
| Under maintenance | `underMaintenance(true|false)` | |
| Alerting suppressed | `suppressAlert(true|false)` | |
| Problem creation suppressed | `suppressProblem(true|false)` | |
| Frequent event | `frequentEvent(true|false)` | Frequent events don't raise problems. |
| Event property | `property.<key>("value-1","value-2")` | Only properties flagged `filterable: true` in the event-properties registry (5.7) can be used this way. No partial-match operators (`contains`/`startsWith`) are supported on event properties or on `eventSelector` generally — only exact-value equality (OR across multiple listed values). If you need substring matching, filter client-side after fetching, or narrow via other criteria (type/entity/time) first. |

There is **no free-text title search** and **no nested `entitySelector(...)` inside `eventSelector`** — use the top-level `entitySelector` parameter for topology scoping.

### 5.4 `entitySelector` (topology scope — identical grammar to the Metrics API)
```
entitySelector=type("HOST"),tag("env:production")
```
Required: `type("TYPE")` or `entityId("id"[,"id2",...])` (all same type). Optional, comma-separated
(AND across criteria, OR within one): `tag("value")` (escape literal `:` in tag key/value with `\`),
`mzId(123)`, `mzName("value")`, `entityName.equals/.startsWith/.in(...)` (wrap in `caseSensitive(...)`
for case-sensitive match), `healthState("HEALTHY"|"UNHEALTHY")`, `firstSeenTms.<lte|lt|gte|gt>(<time>)`,
`<attribute>("v1","v2")` / `<attribute>.exists()`, `fromRelationships.<name>(<selector>)` /
`toRelationships.<name>(<selector>)`, `not(<criterion>)` (inverts anything except `type`). Max 2,000
chars; max **10,000** matched entities for the Events API (vs. 5,000 on Metrics — see §0 cheat sheet).

### 5.5 Response shape (`GET /events` and `GET /events/{eventId}`)
```json
{
  "totalCount": n, "pageSize": n, "nextPageKey": "...",
  "events": [{
    "eventId", "correlationId",
    "startTime", "endTime",                 // UTC ms; endTime is null while still OPEN
    "eventType", "title", "status",          // status: OPEN | CLOSED
    "entityId": { "entityId": { "id", "type" }, "name" },
    "entityTags": [{ "context", "key", "value", "stringRepresentation" }],
    "managementZones": [{ "id", "name" }],
    "properties": [{ "key", "value" }],
    "underMaintenance", "suppressAlert", "suppressProblem", "frequentEvent"   // booleans
  }]
}
```
`GET /events/{eventId}` returns a single Event object (same shape, no wrapper/pagination fields).

### 5.6 GET all event types — `/api/v2/eventTypes`

Enumerates every event type Dynatrace can raise in this environment (144+ types) — use this instead
of guessing an `eventType(...)` string from memory, since the catalog is environment- and
version-specific.
```
GET /api/v2/eventTypes?pageSize=500
```
Params: `pageSize` (max 500, default 100), `nextPageKey` (same omit-everything-else rule as above).
Each entry: `type` (the literal string to use in `eventSelector=eventType("...")`), `displayName`,
`description`, `severityLevel` ∈ `AVAILABILITY | CUSTOM_ALERT | ERROR | INFO | MONITORING_UNAVAILABLE |
PERFORMANCE | RESOURCE_CONTENTION`. Common types worth knowing by heart to skip a lookup on obvious
asks: `PROCESS_RESTART`, `DEPLOYMENT_EVENT`/`CUSTOM_DEPLOYMENT`, `AVAILABILITY_EVENT`, `ERROR_EVENT`,
`PERFORMANCE_EVENT`, `RESOURCE_CONTENTION_EVENT`, `CUSTOM_INFO`, `CUSTOM_ALERT`, `CUSTOM_ANNOTATION`,
`CUSTOM_CONFIGURATION`, `WARNING`, `MARKED_FOR_TERMINATION`, `SYNTHETIC_GLOBAL_OUTAGE`. For anything
less common, call `/eventTypes` rather than guess — an invalid `eventType` value silently returns zero
results, it doesn't error.

### 5.7 GET all event properties — `/api/v2/eventProperties`

The registry of every property key that can appear in an event's `properties[]`, and — critically —
which ones are usable in `eventSelector=property.<key>(...)` (`filterable: true`) vs. which ones are
settable on ingest (`writable: true`).
```
GET /api/v2/eventProperties?pageSize=500
GET /api/v2/eventProperties/{key}       # single property detail
```
Each entry: `key`, `displayName`, `description`, `filterable`, `writable`. Notable keys: the
`dt.event.*` and `dt.davis.*` namespaces carry predefined/system behavior (e.g.
`dt.event.allow_davis_merge` — set `"false"` on ingest to stop Davis AI merging your custom event into
an existing problem; `dt.event.group_label`; `dt.event.description`); `dt.entity.*` keys attach
additional entity context on ingest; anything outside `dt.*` is a free-form custom property.

### 5.8 POST ingest a custom event — `/api/v2/events/ingest`

Pushes an external/synthetic event into Dynatrace (deployments, load-test markers, custom alerts,
decommission markers, etc.). Requires `events.ingest` scope; consumes Davis Data Units (DDUs) from the
events pool — don't fire this speculatively, only when the user actually wants to record an event.

| Field | Required | Notes |
|---|---|---|
| `eventType` | Required | One of: `AVAILABILITY_EVENT`, `CUSTOM_ALERT`, `CUSTOM_ANNOTATION`, `CUSTOM_CONFIGURATION`, `CUSTOM_DEPLOYMENT`, `CUSTOM_INFO`, `ERROR_EVENT`, `MARKED_FOR_TERMINATION`, `PERFORMANCE_EVENT`, `RESOURCE_CONTENTION_EVENT`, `WARNING`. |
| `title` | Required | Free text. |
| `entitySelector` | Optional | Same grammar as 5.4, as a plain string in the JSON body (not query-encoded). Only entities active in the last 24h are eligible except when scoping by literal `entityId(...)`, which bypasses that recency check. If omitted, the event attaches to the environment entity (`dt.entity.environment`). |
| `startTime` | Optional | UTC ms; defaults to now. Problem-opening event types: can't be >6h in the past or >5min in the future. Info-style events (`CUSTOM_ANNOTATION`, `CUSTOM_CONFIGURATION`, `CUSTOM_DEPLOYMENT`, `CUSTOM_INFO`, `MARKED_FOR_TERMINATION`): up to 30 days in the past or 7 days in the future. |
| `endTime` | Optional | UTC ms; defaults to `startTime` + `timeout`. |
| `timeout` | Optional | Minutes; default 15, hard cap 360 (6h). Re-POST the same payload before it expires to keep a problem-opening event alive. |
| `properties` | Optional | Flat key→string map, max 100 entries, key ≤100 chars, value ≤4096 chars. Use `dt.*` keys from 5.7 for predefined behavior, `dt.entity.*` to attach extra entity context, anything else as free-form metadata. |

```json
{
  "eventType": "CUSTOM_INFO",
  "title": "Loadtest start",
  "timeout": 30,
  "entitySelector": "type(SERVICE),entityName.equals(BookingService)",
  "properties": { "Tool": "MyLoadTool", "Load per minute": "100" }
}
```
Response: `201` with `{ "reportCount": n, "eventIngestResults": [{ "correlationId", "status" }] }`,
`status` ∈ `OK | INVALID_ENTITY_TYPE | INVALID_METADATA | INVALID_TIMESTAMPS`.

### 5.9 Root-cause / correlation workflow

The standard "what changed right before this problem" pattern: take the problem's root-cause entity
ID and time window, then scope events to that same entity and a window starting somewhat before the
problem started (deployments/config changes are often the actual trigger, not simultaneous with the
first symptom):
```
GET /api/v2/events?eventSelector=eventType("CUSTOM_DEPLOYMENT")&entitySelector=entityId("<rootCauseEntity.id>")&from=<problemStart-30m>&to=<problemStart>
```
Broaden `eventType` (or drop it) if the deployment-specific query comes back empty — also check
`PROCESS_RESTART`, `CUSTOM_CONFIGURATION`, and generic `entityId(...)` events on the same entity/window
before concluding nothing changed.

### 5.10 Efficiency guidance (apply by default, not just when asked)

To keep Events API answers fast and avoid over-fetching:
- Always scope by `entitySelector` and/or `eventSelector` criteria rather than pulling the full feed
  and filtering client-side — the API does that filtering server-side for free.
- Set `eventType(...)` whenever the user's question implies a category (deployment, restart,
  availability, error) instead of fetching every event type and inspecting titles.
- Keep the time window as tight as the question allows — default `now-2h` is often already too wide
  for "what just happened"; narrow it, and only widen if the first query comes back empty.
- Use `status("OPEN")` for "what's currently affected"-style questions — cuts the result set to active
  events only, no post-filtering needed.
- Don't call `/eventTypes` or `/eventProperties` on every request — the common `eventType` values and
  predefined `dt.event.*` properties are listed in 5.6/5.7; only look them up live when the user asks
  about something unfamiliar or a guessed value returns zero results.
- Respect `pageSize` (up to 1000) to get everything in one page where possible instead of paging; when
  you do need `nextPageKey`, remember it must be the only parameter on that follow-up call.

---

## 6. Security Problems API v2 (Vulnerabilities)

**Base:** `/api/v2/securityProblems`, `/api/v2/securityProblems/{securityProblemId}`

- `securityProblemSelector`: `status(OPEN|RESOLVED|MUTED)`,
  `riskAssessment.riskScore(...)`, `affectedEntities(...)`,
  `vulnerabilityType(CODE_LEVEL|THIRD_PARTY|RUNTIME)`, `technology(...)`.
- `fields=+riskAssessment` — **required** to get `riskScore`/`riskLevel` in
  the list response; omit and you only get bare identifiers.
- `sort=-riskAssessment.riskScore` to get worst-first ordering directly
  from the API rather than sorting client-side.
- Response fields: `securityProblemId`, `status`, `title`,
  `vulnerabilityType`, `technology`, `riskAssessment.riskScore`,
  `riskAssessment.riskVector`, `url`.
- Note the different selector name (`securityProblemSelector`, not
  `problemSelector`) — a common copy-paste mistake when moving from §2.

**Pattern — "top open vulnerabilities in prod, worst first":**
```
GET /api/v2/securityProblems?securityProblemSelector=status(OPEN)&entitySelector=tag("env:production")&fields=+riskAssessment&sort=-riskAssessment.riskScore&pageSize=10
```

---

## 7. Audit Logs API v2

**Base:** `/api/v2/auditlogs` (list), `/api/v2/auditlogs/{id}` (single entry)

- `filter`: `eventType(LOGIN|CONFIGURATION_...)`, `user(...)`,
  `category(...)` — comma/AND semantics as with other selectors.
- `from` / `to`: **required** — no implicit default; **retention is 30
  days** — if the user asks about a change older than that, say so rather
  than returning an empty result silently.
- Response: `entityId` (what changed — e.g. dashboard, alerting profile,
  management zone), `user`, `eventType`, `timestamp`, `patch`/`before`/`after`
  where available.

**Pattern — "who changed X config recently":**
```
GET /api/v2/auditlogs?filter=eventType(CONFIGURATION_MODIFIED)&from=now-7d
```
then match `entityId`/`category` against the config object in question.

---

## 8. SLO API v2

**Base:** `/api/v2/slo` (list), `/api/v2/slo/{sloId}` (single)

- `sloSelector`: `name("...")`, `enabled(true|false)`,
  `managementZoneID("...")`.
- `timeFrame=CURRENT` (SLO's own configured window, default) or
  `timeFrame=GTF` with explicit `from`/`to` to re-evaluate over a custom
  window.
- `evaluate=true` (list endpoint) to get calculated values inline —
  **max pageSize 25** when evaluation is requested, so page if the tenant
  has more SLOs than that.
- Each SLO already carries its own `filter` (an entitySelector, max 1,000
  chars) defining what it measures — read that instead of re-deriving scope.
- Key response fields: `id`, `name`, `status`
  (`SUCCESS`/`WARNING`/`FAILURE`), `evaluatedPercentage`, `errorBudget`,
  `target`, `warning`, `relatedOpenProblems` / `relatedTotalProblems`.

**Pattern — "which SLOs are at risk right now":**
```
GET /api/v2/slo?evaluate=true&pageSize=25
```
Filter the response client-side for `status != SUCCESS`; for each hit,
report `errorBudget`, `relatedOpenProblems`, and its `filter` (the scope).

---

## 9. Network Zones API v2

**Base:** `/api/v2/networkZones` (list/get/put) — **note:** in newer
Dynatrace API versions this is exposed via the Settings API instead:
`/api/v2/settings/objects` with schema `builtin:networkzones.zones`. Check
which one this cluster's version supports (`GET /api/v2/networkZones` first;
fall back to the Settings-API form if it 404s/is deprecated on this
cluster).

- `GET /api/v2/networkZones` — no filter parameters; returns all zones
  with `id`, `alternativeZones`, `numOfConfiguredOneAgents`,
  `numOfConfiguredActiveGates`.
- `GET /api/v2/networkZones/{id}` — single zone detail.
- Use for "which network zone routes traffic for host/OneAgent X" by
  cross-referencing a zone's OneAgent/ActiveGate counts and the host's own
  `networkZoneId` property (visible via Entities `fields=properties`).

---

## 10. Root-cause / topology investigation — fast path

For "why is X slow/down" style questions, execute in this order. Each step
below names the exact selector/field syntax to use so you don't have to
re-derive it — this is what keeps the whole chain to 2–6 calls instead of
trial-and-error round trips. **Stop as soon as you have enough evidence to
answer** — a simple health check needs steps 1–2 (sometimes just 3); a full
RCA narrative needs 1–3, +4/5 as corroboration, and 6–8 only when relevant.

All endpoints below use the Managed URL pattern:
`https://{your-activegate-domain}:9999/e/{your-environment-id}/api/v2/...`

1. **Problems (§2)** — `GET /problems?problemSelector=status("OPEN")&entitySelector=<tag/mz/type>&from=now-24h&fields=+evidenceDetails,+impactAnalysis,+recentComments`.
   One call gives `rootCauseEntity`, `affectedEntities[]`, `impactedEntities[]`,
   and (critically) `evidenceDetails.details[]` — filter that list to
   `rootCauseRelevant:true` and sort by `startTime` ascending to get the
   earliest causal signal instead of just naming an entity. If `rootCauseEntity`
   is `null`, treat the earliest root-cause-relevant evidence item's `entity`
   as the effective root cause. Follow up with `GET /problems/{problemId}?fields=evidenceDetails,impactAnalysis,recentComments`
   for the one problem you're narrating in depth — the detail call isn't
   truncated the way list-embedded evidence can be.

2. **Entities (§1)** — `GET /entities/{rootCauseEntity.entityId}?fields=fromRelationships,toRelationships,tags,managementZones,properties.*`
   (or `GET /entities?entitySelector=entityId("...")&fields=+fromRelationships,+toRelationships,+tags,+properties.*`
   for the list form). This resolves the **dependency chain** — e.g. for a
   `PROCESS_GROUP_INSTANCE`: `toRelationships.isProcessOf` → `HOST`,
   `fromRelationships.runsOn`/`calls` → downstream services. Chain outward
   one hop at a time (root cause → `runsOn`/`runsOnHost` → host →
   `isInstanceOf` → host group) to build the propagation narrative; don't
   stop at one entity's immediate neighbors if the question needs the full
   path. Use `GET /entityTypes/{TYPE}` once (cache the result) if you need
   to discover which relationship/property names exist for a type you
   haven't queried before.

3. **Metrics (§3)** — `GET /metrics/query?metricSelector=<builtin metric for the entity type>&entitySelector=type("...")​,entityId("...")&from=<problem.startTime-15m>&to=<problem.endTime or now>&resolution=1m`.
   Match the metric to the entity type: `builtin:host.cpu.usage`/`builtin:host.mem.usage` for
   `HOST`; `builtin:service.response.time`/`builtin:service.errors.total.rate`
   for `SERVICE`; `builtin:tech.*` for process-level. **Always scope `from`/`to`
   to the problem's own window** (pull a few minutes of lead-in before
   `startTime` to see the change point), not an arbitrary default — this is
   what turns "CPU was high" into "CPU jumped from 40% to 97% at the exact
   moment the problem started." Cap at 10 metrics per query; use
   `:splitBy("dt.entity.<type>")` when comparing across several entities in
   one call.

4. **Logs (§4)** — `GET /logs/search?query=dt.entity.<type>="<entityId>"&from=<window>&to=<window>&sort=-timestamp&limit=1000`.
   Use the entity ID directly in the `query` parameter (Dynatrace search
   query language — this is a `query` string, **not** an `entitySelector`
   param, and there is no built-in loglevel filter param — express it in
   `query`, e.g. `query=dt.entity.host="HOST-..." AND loglevel="ERROR"`).
   `limit` caps at 1000 records per call; if you need more, page with
   `nextSliceKey` or switch to `/logs/export` (uncapped, but paginated
   instead of sliced). This is a first-pass error scan, not the primary
   evidence source — treat log hits as corroboration for what `evidenceDetails`
   already flagged, not a new root cause unless nothing else explains the
   symptom.

5. **Events (§5)** — `GET /events?eventSelector=eventType("CUSTOM_DEPLOYMENT","PROCESS_RESTART","CUSTOM_CONFIGURATION")&entitySelector=entityId("...")&from=<window>`.
   Purpose-built to catch deployments/restarts/config pushes as candidate
   triggers that Davis evidence may not have flagged as root-cause-relevant.
   Cross-check the event's `startTime` against the problem's `startTime` —
   an event landing within seconds/minutes before problem start is a strong
   causal candidate even if Problems API evidence didn't surface it.

6. **Security Problems (§6)** — only if the entity/component is
   vulnerability-relevant to the question: `GET /securityProblems?securityProblemSelector=status("OPEN")&fields=+affectedEntities,+riskAssessment&sort=-riskAssessment.riskScore`.
   Note the different selector name (`securityProblemSelector`, not
   `problemSelector`) and that `riskAssessment` must be explicitly requested
   via `fields=+riskAssessment` — it isn't included by default.

7. **SLOs (§8)** — only if the user cares about SLA/error-budget impact.
   Pull the SLO evaluated for the same window to state whether the incident
   burned error budget, not just that it happened.

8. **Audit Logs (§7)** — only if a human-made config change is suspected as
   the trigger: `GET /auditlogs?filter=eventType(...)&from=<window slightly
   before problem start>`. Managed retains audit logs 30 days by default —
   if the problem is older than that, say so rather than reporting a false
   "no config changes found."

### Synthesis rule
Don't stop at "step 1 named an entity" — a complete answer states: **what
changed** (metric/event delta from step 1/3/5, with before→after numbers),
**on what entity** (step 1/2), **how it propagated** (relationship chain
from step 2), and **who/what it hurt** (impactAnalysis from step 1,
quantified). Corroborating log/event hits (steps 4–5) support that
narrative; they don't replace it.

---

## 11. Tenant-specific fill-ins (edit only this section over time)

- Tagging convention actually in use: `env:`, `app:`, `team:`, `layer:` —
  confirm keys with the user once, reuse everywhere.
- Primary management zones and their priority ordering (e.g. production
  outranks staging/dev for triage).
- Environment alias(es) if multiple Managed tenants are configured in
  `DT_ENVIRONMENT_CONFIGS` / `dt-config.yaml` — always state which
  environment an answer came from.
- Confirm on first use whether this cluster's Network Zones are still
  served by `/api/v2/networkZones` or have moved to the Settings API
  (`builtin:networkzones.zones`) — clusters differ by version.
- Confirm this cluster's actual log retention window (up to 35 days by
  default, but configurable) rather than assuming the maximum.

Everything above this section is derived from the Dynatrace Managed v2 API
contract itself and should not need to change as the tenant grows.