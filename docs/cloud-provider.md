# Optional cloud provider

The default workspace is offline. No production service address, session, token,
private schema, personal save, or game artwork is bundled. Constructing a cloud
provider and opening its UI perform no network requests. Public help and
recommendations load only after their buttons are clicked.

An application build may supply `--dart-define=TERRAFORGE_CLOUD_ORIGIN=https://service.example/api`.
`CloudServiceConfig.viewer` appends the verified viewer routes to that HTTPS API
base (an optional path prefix is preserved). This exposes public help and
recommendations through the actual cloud/account panels. The example address is
not a service configuration. Local tools work without this setting. Hosts can
also supply `TERRAFORGE_CLOUD_TENANT_ID` and `TERRAFORGE_CLOUD_TERMINAL` (or the
matching config fields), using the identifiers approved for that deployment.
The reference attaches tenant-id and terminal to its same-origin JSON, multipart
and binary requests. No tenant or mini-program terminal is silently selected
for this cross-platform host; deployments requiring them must configure them.

A host can instead inject `CloudBackend(api: HttpCloudApi(config: ..., client: ...),
auth: ..., session: ...)` into `Workspace` or `CloudWorkspacePanel`. An injected
`CloudApi` may adapt another explicitly configured service. The host owns its
HTTP client and authentication adapter. No endpoint discovery, credential entry,
or silent sign-in is performed.

## Platform packaging

Android release INTERNET permission and macOS network.client entitlements were
explicitly approved and added by the integration owner. These packaging settings
enable configured outgoing requests; they do not establish a live service/account
connection. All client tests below remain local and synthetic.

## Authentication boundary

Read-only inspection of viewer-boot revision
`1f8347c69f370b24463ae35f253d855dfef19423` found a WeChat mini-program initial
MEMBER login and refresh-token flow, but no verified portable initial MEMBER
login suitable for this Flutter application. The admin/system login is not an
acceptable replacement. `UnavailableAuthProvider` therefore reports that a
supported adapter is required, rather than manufacturing a signed-in account.

A host-provided session contains an in-memory access token, expiry, and stable
`accountId` from the authenticated login response `userId` or authenticated
profile `id`. Display names and token text must never become account identity.
Private saves, uploads, profile edits, generation and recommendation mutations
require a valid session. Recommendation downloads and transfers additionally
require that stable identity for recovery. Sign-out clears local session state
and cancels active transfers. A remote viewer logout route is not assumed.
Session changes discard stale asynchronous UI results. Tokens are never written
to the operation journal or local vault.

## Source-verified wire contract

The runtime routes match the readonly viewer reference at revision
`366ebc57751cadfb077f968f4d5069028b3bf9a6`, including
`infrastructure/api/cloud-saves.ts`, `recommendations.ts`, `helper-info.ts`,
`world-generation.ts`, and `features/saves/services/{cloud-saves,recommendations}.ts`.
Backend contract verification used the viewer-boot revision above. This is source
and synthetic-test evidence, not live account verification.

All JSON responses use `{ "code": 0, "data": ... }`.

| Logical operation | HTTP contract |
| --- | --- |
| listSaves | GET `/viewer/cloud-saves/list`, pageNo/pageSize/kind |
| getSave | GET `/viewer/cloud-saves/get?id=...`, authenticated latest record |
| duplicate | GET `/viewer/cloud-saves/duplicate`, kind/SHA-1 hash/fileSize |
| upload | POST `/viewer/cloud-saves/upload`, multipart file + kind/fileName, world PNG preview |
| download | GET `/viewer/cloud-saves/download?id=...`, authenticated raw binary |
| deleteSave | DELETE `/viewer/cloud-saves/delete?id=...`, Boolean confirmation |
| recommendations | GET `/viewer/recommendations/list`, pageNo/pageSize/kind |
| getRecommendation | GET `/viewer/recommendations/get?id=...` |
| likeRecommendation | POST `/viewer/recommendations/like`, JSON id |
| recommendationTicket | POST `/viewer/recommendations/download-ticket`, JSON id/requestId |
| recommendationDownload | GET `/viewer/recommendations/download?operationId=...`, authenticated raw binary |
| recommendationComplete | POST `/viewer/recommendations/download-complete`, JSON operationId |
| recommendationTransfer | POST `/viewer/recommendations/transfer`, JSON id/requestId |
| recommendationOperation | GET `/viewer/recommendations/operation?operationId=...` |
| help | GET `/viewer/helper-info/searchAllHelperInfo`, title/content articles |
| profile | GET `/viewer/user-info/getUserInfo`, authenticated current account |
| updateProfile | POST `/viewer/user-info/updateAppUserInfo`, id/nickname/avatar |
| options | GET `/viewer/world-generation/options`, enabled/versions/schema |
| submit | POST `/viewer/world-generation/submit`, generation request |
| refresh | GET `/viewer/cloud-saves/get?id=...` |
| retry, cancel | POST `/viewer/world-generation/retry` or `/cancel`, id query |

A private cloud save is never interpreted as a JSON download ticket. Its latest
owner-checked record must be ready before transferring bytes. A recommendation
is re-read before an action; hidden/unready items cannot start a download. Only
recommendations use operation tickets. The ticket must contain the exact relative
`/viewer/recommendations/download?operationId=<UUID>` path. Response-supplied
origins, extra query parameters, redirects, expired tickets, invalid names,
invalid identifiers and unexpected file lengths are rejected. All authenticated
requests remain on the configured origin. JSON and binary streams have byte
limits; downloads enforce both the advertised size and the final byte count.

## Durable publication and recovery

The workspace publishes cloud bytes and metadata into its local vault, then
reads them back and checks SHA-256 and length before reporting adoption. Missing
storage, write failures and corrupt reads fail adoption. Existing immutable
content is reverified and reused. Cancelling an optional system export does not
remove an already adopted local file. Recommendation completion is sent only
after successful durable adoption. It is never inferred from merely receiving
bytes or opening a system picker.

A failed completion receipt leaves the local file available and queues the
operation ID for explicit retry. The queue persists across restarts and is keyed
by SHA-256 of the configured service origin, tenant ID, terminal and authenticated
stable account ID. The v2 namespace never replays ambiguous older v1 queues.
Only operation/request identifiers are stored, never tokens or profile fields.
If local preference storage is temporarily full, the saved file is retained and
the UI explicitly reports that the retry is only in memory. The queue is bounded
to 1000 receipts; each retry handles at most 20. Unredeemable 403/404/410 receipts
are retired; transient failures remain retryable.

A transfer request ID is durably journaled before its POST. An uncertain response
retries the same request ID. Once a pending operation ID is known, subsequent
attempts query that operation instead of starting another copy. These records
are account/service/tenant/terminal scoped and bounded to 256. Corrupt journal records block new
transfers rather than being silently replaced. Concurrent operations and repeated
clicks are guarded; cancellation and session changes stop adoption or receipts
for stale operations.

The viewer adapter caps save transfers at the verified backend maximum of 100 MiB
(and image uploads at 10 MiB); upload names are limited to 180 characters and the
matching extension. Selecting a .wld.bak/.plr.bak backup proposes the matching
.wld/.plr cloud filename in the confirmation without changing the source file.

Uploads snapshot selected bytes and bind the confirmation to the session that
selected them. The backend performs the reference SHA-1/size duplicate check
before multipart upload. World uploads require a real engine-rendered PNG preview, which is attached to
the supported multipart preview field. Rendering temporarily opens the selected
immutable WLD and restores the user’s active WLD on success or failure. Missing
or failed preview generation blocks the upload. Player preview/equipment fields
are optional on the inspected backend; equipment preview generation is not yet
provided. The backend requires a MEMBER account with a WeChat openid for a new
upload; client capability does not bypass that service-side requirement.

## Account, help and generation UI

Profile loading retains only id/nickname/avatar. The editor validates nickname
length and supports HTTPS avatar URLs or service-relative resource paths,
including explicit empty-avatar reset. It sends only the verified profile fields;
there is no invented avatar upload endpoint. Avatar images load only when the
user requests them, with no session header and a fallback on image failure.

Help has idle, loading, empty, error/retry and expanded article states. Articles
render bounded plain text: scripts/styles/embedded elements are removed and
HTML entities are decoded without executing HTML or fetching embedded images.

Generation options and schema remain runtime service data. Schema validation
rejects unknown fields, read-only edits, invalid references/types, bounds and
choice violations. Lists/maps are capped at 256 and nesting at 12. Polling starts
only after explicit submission/tracking, stops at terminal states or disconnect,
and pauses on failure. A lost submission response blocks resubmission until the
user reconciles the job from the cloud save list.

## Verification

`cloud_test.dart`, `cloud_reference_contract_test.dart` and
`cloud_account_help_ui_test.dart` exercise in-process mocks and synthetic bytes:
exact routes and authorization, stream bounds, redirect/ticket rejection,
readiness/identity checks, durable-vault failures, receipt ordering, account
isolation, restart recovery, uncertain transfers, cancellation, field filtering,
help/avatar validation and UI actions. No live service requests, real account
mutations, credential changes or uploads occur in these tests.
