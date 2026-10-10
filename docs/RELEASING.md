# Verified main previews

`Publish verified main preview` publishes a GitHub **prerelease** after the existing
`Flutter CI` completes successfully for a push to `main`. PR/fork runs are never
eligible. It does not merge PRs, change performance gates, deploy software, submit
stores, or create signing keys or other persistent credentials.

## Version and source

The application version remains the version in the verified commit's pubspec
(currently `0.1.0+1`). With no pre-existing repository tags/releases, preview tags
use `v<major.minor.patch>-preview.<CI run number>.<12-character source SHA>`.
The tag points to the full, exact verified SHA. Every package is taken from that
same run. Each verified main SHA has its own preview, including a main commit that only updates publishing configuration.

The workflow's path-filtered main push trigger bootstraps the first already merged
build, Flutter CI run `38007059507` at
`cf36cd2bf1d447a887d3ea4d19611020368de22c`. Subsequent workflow-file edits only inspect the published bootstrap tag and asset metadata; they cannot replace it and do not require retained CI artifacts. A manual or workflow-run full verification still requires the original unexpired artifacts. `workflow_dispatch` accepts a successful main CI
run ID for explicit recovery of another missed completion. Future main builds use
`workflow_run` automatically.

## Verification and limits

The publisher re-reads the CI run and all five jobs, checks same-repository main
ancestry, requires four SHA-named non-expired artifacts, verifies their archive
SHA256 digests, and accepts only the expected five package files. It never executes
package contents. Artifacts are downloaded as data with bounded archive handling.
The checked-out publisher is from the trusted workflow SHA on main, not the source
of an untrusted triggering workflow.

Release assets:

- `terraforge-android-unsigned.apk`: unsigned; cannot install as-is
- `terraforge-ios-unsigned.tar.gz`: unsigned Runner.app; not an installable signed IPA
- `terraforge-macos-unsigned.tar.gz`: unsigned and not notarized
- `terraforge-linux.tar.gz`: Linux x64 bundle
- `terraforge-web.tar.gz`: static Web bundle; serve over HTTP(S)
- `BUILD-PROVENANCE.json`: full source SHA, run, artifact digests and package hashes
- `SHA256SUMS`: checksums for the five packages and provenance file

No Windows package exists. Functional build success is not performance, in-game,
or real-device certification. Earlier evidence includes failing performance comparisons and no demonstrated memory plateau across eight cycles. Real-device smoothness remains unmet or unverified; a successful correctness/report-generation workflow does not establish those performance acceptance goals. The publisher always marks releases as previews
and includes these warnings. Review and explicitly update the acceptance wording
when new evidence justifies it; no automatic stable promotion exists.

## Minimal permissions and recovery

Only the publish job has `contents: write`, plus `actions: read` to download the
verified artifacts. The built-in job-scoped GITHUB_TOKEN is used without saving
credentials. There are no PATs, signing secrets or new persistent grants.

Per-build release concurrency has `cancel-in-progress: false`; different source builds cannot evict one another from the pending queue. A release is created
as a draft, all seven assets are uploaded and verified, then the draft is published
with `prerelease: true` and `make_latest: false`. Recovery can upload missing assets
to an identical draft, but never overwrite assets, delete a release, or repoint a
tag. Any unexpected existing asset/hash, target or draft notes fails closed.
Already published releases are verified read-only and left unchanged. A failed GitHub upload may leave an empty `starter` asset: this fails closed and requires owner review/manual cleanup; the publisher never deletes it.

Local publisher guard tests:

```sh
python3 -m unittest discover -s tool/release -p '*_test.py' -v
```

GitHub references: [workflow-run security](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run),
[releases API](https://docs.github.com/en/rest/releases/releases),
[Actions artifact API](https://docs.github.com/en/rest/actions/artifacts).
