/* Independent sampled diagnostic adapter. No application/launcher wiring here. */
#ifndef ABC_SAMPLED_WRAPPER_H
#define ABC_SAMPLED_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ABC_SAMPLE_ABI 1u
#define ABC_SAMPLE_PARAMETER 524288u
#define ABC_SAMPLE_RAW_LIMIT 1048576u /* accepted bytes must be strictly less */
#define ABC_SAMPLE_HOOK_NS UINT64_C(10000000000)
#define ABC_SAMPLE_ENABLE_ENV "ABC_SAMPLED_DIAGNOSTIC"
#define ABC_SAMPLE_PENDING_NAME "q0.sample.heap.pending"
#define ABC_SAMPLE_FINAL_NAME "q0.sample.heap"

enum abc_sample_error {
  ABC_SAMPLE_OK = 0,
  ABC_SAMPLE_DISABLED = 1,
  ABC_SAMPLE_BAD_INIT = 2,
  ABC_SAMPLE_BAD_ENV = 3,
  ABC_SAMPLE_PROVIDER = 4,
  ABC_SAMPLE_ALREADY_ATTEMPTED = 5,
  ABC_SAMPLE_WRONG_CUT = 6,
  ABC_SAMPLE_CLOCK = 7,
  ABC_SAMPLE_EXCEPTION = 8,
  ABC_SAMPLE_BAD_ALLOC = 9,
  ABC_SAMPLE_EMPTY = 10,
  ABC_SAMPLE_TOO_LARGE = 11,
  ABC_SAMPLE_TIMEOUT = 12,
  ABC_SAMPLE_OUTPUT = 13,
  ABC_SAMPLE_WRITE = 14,
  ABC_SAMPLE_SYNC = 15,
  ABC_SAMPLE_CLOSE = 16,
  ABC_SAMPLE_PUBLISH = 17
};

struct abc_sample_config {
  unsigned abi;
  int output_directory_fd; /* borrowed; caller retains ownership */
  uint64_t output_device;
  uint64_t output_inode;
  void *provider_guard_user;
  /* Required sealed-launcher identity check; 1 means the fixed official
   * provider and target still match. It must not sample, start/stop profilers,
   * change the environment, or register another MallocExtension. This hook is
   * deliberately not implemented by this isolated offline deliverable. */
  int (*provider_matches)(void *);
};

struct abc_sample_result {
  unsigned abi;
  int status;
  int accepted;
  unsigned api_calls;
  unsigned provider_checks;
  unsigned output_opened;
  unsigned output_close_attempts;
  unsigned output_closed;
  int cleanup_errno;
  int io_errno;
  int published;
  int api_returned; /* false for a thrown call; bytes may then be partial */
  uint64_t hook_start_ns;
  uint64_t api_start_ns;
  uint64_t api_end_ns;
  uint64_t api_elapsed_ns;
  uint64_t hook_end_ns;
  uint64_t returned_bytes;
  uint64_t returned_capacity_bytes;
  uint64_t written_bytes;
  /* Output and elapsed checks happen after return. Neither constrains the
   * API's dynamic-allocation peak or preempts a blocked API/system call. */
};

/* Initialize the entire context to zero, once, before initialize. All calls
 * must be serialized by the target's existing synchronous quiet hook. Do not
 * share contexts between threads or reset/reinitialize one to obtain retries.
 * No constructor/destructor, signal, background thread, or implicit trigger. */
struct abc_sample_context {
  unsigned initialized;
  unsigned consumed;
  struct abc_sample_config config;
  struct abc_sample_result result;
};

unsigned abc_sample_abi(void);
int abc_sample_initialize(struct abc_sample_context *,
                          const struct abc_sample_config *);
/* The only supported cut is cycle == 0. Every call consumes the single slot,
 * including failure. A repeated call never invokes the API or writes again;
 * its error return leaves the first attempt's result unchanged.
 * Reads current env without mutation: own enable flag must be exactly "1",
 * TCMALLOC_SAMPLE_PARAMETER exactly "524288", no HEAP* profiler variables.
 * The launcher must set P before process startup; current env alone does not
 * prove the sampler used P. Offline parser must verify heap_v2/524288 too.
 * accepted means transport completed, even if raw bytes contain invalid
 * syntax/NUL. Such bytes are preserved intact for offline rejection/evidence.
 * Parser/maps/provider/observer evidence
 * is still required before accepting a diagnostic. This is estimated sampled
 * live data, never the old full-profiler four-column cumulative accounting. */
int abc_sample_capture_q0(struct abc_sample_context *, int cycle);

#ifdef __cplusplus
}
#endif
#endif
