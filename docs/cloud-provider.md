# Optional cloud provider

The default workspace is disconnected. No endpoints, login credentials, tokens,
private schemas, or source-service configuration are bundled. Local tools require
no cloud session. Constructing a provider or displaying the panel makes no request.

A host can inject `CloudBackend(api: HttpCloudApi(config: ..., client: ...),
session: ...)` into `CloudWorkspacePanel`. The host supplies an approved HTTPS
`CloudServiceConfig`, logical route names, declared capabilities and a supported
identity adapter. The available legacy identity flow is platform-specific; a
cross-platform backend login adapter remains an integration prerequisite. The
provided `UnavailableAuthProvider` clearly refuses unsupported login. Sessions
are in-memory only and are dropped on disconnect/disposal. No refresh token is
persisted or embedded. Session expiry requires the host to supply a fresh session.

## Runtime route contract

- `listSaves`: GET, pageNo/pageSize/kind; paginated private save records
- `upload`: multipart POST, file + kind/fileName; private save record
- `download`: GET with id; a downloadUrl ticket
- `recommendations`: GET with pageNo/pageSize/kind; paginated recommendation records
- `profile`: GET; account object
- `updateProfile`: POST; id/nickname/avatar fields
- `options`: GET; enabled, versions, schema (revision/root/types)
- `submit`: POST; world name/version/seed/size/difficulty/evil/config/revision
- `refresh`: GET with id; latest save/job record
- `retry`, `cancel`: POST with id; updated job record

JSON responses use `{ "code": 0, "data": ... }`. Deployments with a different
wire contract should implement `CloudApi` instead of embedding private endpoint
knowledge in the app. Download-ticket compatibility must be verified by the host.
Generation values and option schema are runtime service data, not a shipped
copy of a private service schema. Size/difficulty/evil vocabulary in the panel is
small/medium/large, classic/expert/master/journey, random/corruption/crimson;
a differing backend should adapt these at its `CloudApi` boundary.

## Safety and lifecycle

Service authorization headers are confined to the configured origin. Redirects
are disabled. Signed downloads require an explicit HTTPS origin allowlist and
receive no session headers. JSON and download streams have byte caps and timeouts;
uploads are bounded and accept explicit cancellation. Errors shown to users do
not include server response bodies, URLs, or credentials. File picker/upload and
local download destination handling are host callbacks, always user-triggered.
The host owns and closes its injected HTTP client when no longer needed.

Generation jobs have typed states including queued, running, cancelling, terminal
and unknown. Polling starts only after explicit submission/tracking, pauses on
request failure, and stops at terminal states, disconnect or disposal. Retry and
cancel are explicit actions. Concurrent submission is blocked. A lost submit
response blocks further submissions until the user reconciles a job from the save
list; this deliberately does not claim server-side exactly-once semantics.

Schema validation rejects unknown fields, read-only edits, invalid references,
unsupported kinds, invalid primitive types, numeric bounds and choice violations.
Lists/maps are capped at 256 entries and nesting at 12. Objects are expanded lazily;
list/map editors accept JSON and surface validation errors. Omissions retain
service defaults. The panel provides cloud save listing, recommendations, profile
nickname editing, generation options and job controls. Recommendation likes,
counted downloads, transfers, preview images and provider-specific account flows
are not implemented by the generic adapter and must not be advertised as live.

All provider tests use `http/testing.dart` MockClient or in-process futures.
No live service calls or real uploads are performed during verification.
