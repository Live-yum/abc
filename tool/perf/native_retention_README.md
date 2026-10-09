# Fixed-product native retention diagnostic: review package

Prepared for review; no CI, publication or full-world run has been started.
The workflow is restricted to one dedicated branch push. Product pin: `661f9f17531e87f0b3f9f7028d70a94814c21234`, tree
`9ff4ca286afa3e545901c498de167ee0c5dfc61d`. This is the final READ-buffer and
failed-close candidate, not the earlier fixed-old-product control.

## Bounded question and workload

The next observation asks whether same-quiet process growth accompanies an
increase in glibc **allocator-accounted in-use** space, glibc free arena space,
direct malloc mappings, or OS mapping categories that these numbers do not
explain. It does not assert which component owns an allocation.

One fresh Linux/profile process runs exactly the existing eight-cycle
`runComputerMemoryDiagnosticCycle` body from the pinned product. Its initial
cancellation, import, Pong, 4,096 pulses, pause, reset/save/reopen, close, disposal,
frame-prefix release and all existing time windows remain unchanged. Only the
public pinned Computerraria WLD is permitted; no TWLD or private files.

Predeclare cycles **0–3 as first-use warm-up variants**, with **4–7 one repeat
of those four variants**. Preserve all eight absolute values, every frame,
startup, cancellation, outlier and tail. Four repeated variant points are not a
long-term test or a plateau. No cycle is dropped and no threshold is introduced.

Keep the prior OS-only target's timing-only schedule, including its nominal
replacement waits. The schedule source stays `51bc8ea`; it is not the product
identity. Actual lateness remains recorded. Each quiet still has three 16 ms
frame barriers plus at least 1,200 ms real waiting. The short `pre-next-work`
endpoint remains short. Existing in-process and external OS samplers remain.

The profile integration driver may use the VM service. The diagnostic makes
**no AllocationProfile/GC or other VM memory-probe requests**. No authentication,
service flags, sandbox, graphics configuration, allocator tunables, trim or
extra collection is changed.

## Observer and exact boundaries

`native_retention_probe.c` is an independent CI helper compiled against that
runner's official `malloc.h`. It is never linked into `libabc_engine`, copied
into a product bundle or placed on a normal app import path. Dart loads it only
from the explicit absolute `ABC_RETENTION_HELPER` file. The C code accesses
named official struct members; its cross-language ABI is 16 uint64 words.

Before baseline, open the helper, resolve symbols, allocate one **128-byte**
buffer and preserve one initialization sample. Reuse that buffer until after
the final evidence boundary. Capture two calls around each of exactly **18**
external observations: baseline.pre, retained-quiet.end and released-quiet.end
for all eight cycles, then final-quiet.end. Total: **37 calls including first
use**. Every call records Dart start/end timestamps and sequence, and is flushed
to a separate small JSONL before returning. Completed calls survive later
request/ack failures; partial runs are not valid complete evidence. The OS
request/ack uses the existing bounded verified-PID protocol; Python and Dart
clock epochs are never subtracted.

The before/after values are separate observations, not a min/max choice or
an atomic snapshot. Request serialization, acknowledgement decoding, journals,
the C call and the helper's fixed allocation are observation work. No measured
observer amount is subtracted from product memory. There is no new control arm.

`RetentionOsSampler` retains the existing 10 ms status / 100 ms rollup sampler
and adds one separately timed rollup read at each of those 18 endpoints. It
records Pss_Anon, Pss_File and Pss_Shmem plus existing scalar rollup fields. It
never opens full smaps/maps, records addresses/paths, or reads another process's
memory. The inherited identity check reads ancestor stat solely to prove the
newly launched app belongs to its runner. Every extra read is journaled before
acknowledgement with its own times and hash manifest. Absent optional kernel
fields remain null; malformed required data fails the diagnostic.

## glibc semantics checked against implementation

The local installed official header is glibc **2.41**, with ten size_t fields;
size_t is 8 bytes and the struct is 80 bytes here. C static assertions check each
offset and total size. A small fresh C process compares every shim field to a
direct header-defined mallinfo2 call. CI must compile again and record its own
compiler, header hash, runtime libc version/package identity, helper hash,
product native binary hash and actual final-product source identity. Do not
assume Ubuntu's libc version from its runner label.

Upstream glibc [2.39 malloc.c](https://raw.githubusercontent.com/bminor/glibc/refs/tags/glibc-2.39/malloc/malloc.c)
and [2.41 malloc.c](https://raw.githubusercontent.com/bminor/glibc/glibc-2.41/malloc/malloc.c)
were inspected at int_mallinfo and __libc_mallinfo2. Both visit all arenas,
locking them individually. Per arena, they count top/free-bin space, set
uordblks from system_mem minus that space, and accumulate arena. Direct malloc
mappings are recorded separately as hblkhd. keepcost is only the main arena's
top chunk. Neither traversal counts per-thread tcache as free bins, so blocks
already freed into tcache can remain in uordblks. Arena metadata and internal
rounding also prevent interpreting it as exact application-live payload.

These upstream releases establish the inspected implementation model, not the
identity of every distribution patch. The local image has no libc package
entry in dpkg-query; that package/source identity remains unavailable. A CI
libc version outside the inspected 2.39/2.41 families requires fresh source
review before attributing its values. Retain unfamiliar versions as raw data.

The helper verifies that resolved malloc/calloc/realloc/free and mallinfo2
belong to the same DSO as gnu_get_libc_version. This detects ordinary global
allocator interposition; it cannot account for library-private allocators,
direct mmap, Dart VM pages, engine/graphics owners, or prove all callers use
those global symbols. Unsupported headers/symbols or unverified allocator
identity produces explicit unavailable/null fields, never a fabricated zero.

## Interpretation contract

- List raw `uordblks` as allocator-accounted in-use, `fordblks` as allocator
  free arena space, `arena` and `hblkhd` separately. Do not label uordblks
  application-owned, leak bytes, or all native memory.
- Compare all matched released-quiet absolute values and same-mode/scenario
  pairs 0→4, 1→5, 2→6 and 3→7. Also retain retained-quiet and final-quiet values.
- Rising uordblks is compatible with retained allocator-accounted in-use but
  does not prove unreachable or leaked ownership. Rising fordblks is evidence
  of allocator free capacity; these virtual totals are not resident-byte totals.
- OS category changes can narrow which kind of mappings contributes. They
  cannot identify Dart, engine, graphics or a specific native owner. Divergence
  remains unexplained, not a computed residual named “other native”.
- Never subtract a malloc value from RSS, sum overlapping views, infer leak
  freedom, or derive an FPS/jank pass. PSS categories are kernel accounting,
  with rounding and independent read times. See the [kernel proc documentation](https://www.kernel.org/doc/html/latest/filesystems/proc.html).

## Review files and next integration gate

- `integration_test/computer_native_retention_test.dart`: dedicated target;
  reuses the original cycle; new schema `abc.native-retention.v1`.
- `integration_test/support/native_retention_probe.dart`: one reusable buffer,
  explicit supported/null mapping, sequence and elapsed-call metadata.
- `tool/perf/native_retention_probe.c`: small header-defined observation shim.
- `tool/perf/native_retention_protocol.py`: existing runner protocol adapter,
  endpoint-only rollup categories and focused protocol validation.
- `native_retention_probe_test.py`, `native_retention_probe_contract.dart` and
  `native_retention_protocol_test.py`: lightweight boundary/error contracts.

The dedicated `.github/workflows/native-retention.yml` listens only to pushes
on `codex/native-retention-661f9f17`; it has no PR trigger or auto-PR action.
Existing main/PR workflows remain byte-for-byte unchanged. Permissions are only
`contents: read`; no artifact-reading permission or stored-run download is
needed because the fixed schedule is already in the pinned product.

`native_retention_prepare.py` uses separate workflow and product checkouts plus
an external evidence directory. It preserves every original Git blob/mode and
actual file byte, copies only new diagnostic files, and makes a local-only
**derived commit**. Both PERF_COMMIT and checkedOutHead identify that derived
commit. `workingTreeDirty=false` means the derived tracked source/index is
clean, including committed diagnostics; it does not claim the directory lacks
ignored build outputs or that its HEAD equals the original product pin.
Original and derived product IDs, tree IDs, full patch and source manifests are
kept separately. Hidden/ignored tracked files and assume-unchanged/skip-worktree
flags do not exempt any tracked bytes from verification.

CI resolves the unchanged lockfile, then runs target analysis, formatting and
lightweight inherited/new contracts. It builds the independent helper outside
the product checkout, recording its official headers, compiler, actual libc,
package metadata and fresh-C ABI contract. It resolves the existing public WLD
and observed software renderer using the original settings. Nothing connects
to an existing app, browser or another user's process.

`native_retention_run.py` compiles the dedicated profile target first, records
its exact artifacts, then uses the pinned SDK's Linux prebuilt-executable
support with the unchanged integration driver. It invokes exactly one fresh
application process; no compile failure can launch a workload. The total
build/driver deadline starts before compilation: **300 seconds build+hello,
600 seconds from app hello, 900 seconds total**. No retry follows a failure.
A successful process must retain identical source/helper/product binary bytes.

`native_retention_validate.py` reuses the old OS-only workload, frame, action,
quiet, checkpoint, sequence, native lifecycle and in-process OS rules. Its
external OS validator preserves the previous checks with the new real arm and
product IDs. It adds exact 37-call / 18-category JSONL reconciliation, all 79
external endpoints, source/derived patch/build/helper hashes and complete raw
inventories. Original target reports and compiler provenance are preserved;
separate enriched copies contain explicit provenance attachments.

Unsupported observations can be structurally complete, but the summary and
execution status say **inconclusive**, with allocatorAttributionAvailable=false
and memoryImprovementEstablished=false. Missing/partial/malformed observations
fail evidence validity. Uninspected libc families also remain inconclusive.
The workflow always uploads completed or partial raw logs, calls, endpoints,
frames and provenance; it never uploads the WLD/TWLD, user files or an app bundle.
Only the small diagnostic helper and ABI-contract binaries are retained.

Local review commands require no world, network or Flutter process:

```sh
ABC_CONTRACT_DART=/path/to/pinned/dart python3 -m unittest discover \
  -s tool/perf -p 'native_retention*_test.py' -v
dart --suppress-analytics format --output=none --set-exit-if-changed \
  integration_test/computer_native_retention_test.dart \
  integration_test/support/native_retention_probe.dart \
  tool/perf/native_retention_probe_contract.dart
```
