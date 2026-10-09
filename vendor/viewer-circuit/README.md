# Retained viewer circuit source

This is the exact 40-module build closure from `Live-yan/viewer-app` commit
`366ebc57751cadfb077f968f4d5069028b3bf9a6`. Original relative paths and file bytes
are preserved. `retrieved-source-manifest.json` contains only those files, with
their verified upstream Git blob IDs and sizes.

Build from the repository root with `npm ci` and `npm run build:circuit-rules`.
No private checkout or upstream repository access is required. The root helper
verifies every bundled source against the manifest before writing runtime
artifacts and provenance. Run `npm run verify:sources` to check the distributed
source subsets and runtime hashes.

See `../../THIRD_PARTY_NOTICES.md`. Publication of this authorized subset does
not grant a new upstream license or relicense its contents.
