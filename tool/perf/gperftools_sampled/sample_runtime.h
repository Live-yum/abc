/* Independent sampled q0 runtime. No implicit trigger or full-profiler API. */
#ifndef ABC_SAMPLE_RUNTIME_H
#define ABC_SAMPLE_RUNTIME_H
#include <stdint.h>
#define ABC_SAMPLE_RUNTIME_ABI 1u
#define ABC_SAMPLE_MAP_CAP 1048576u
#define ABC_SAMPLE_METADATA_CAP 16384u
#define ABC_SAMPLE_ACK_NS UINT64_C(2000000000)
#define ABC_SAMPLE_RECEIPT_CAP 512u
#define ABC_SAMPLE_RECEIPT_NAME "q0.sample.receipt"
#define ABC_SAMPLE_ACK_NAME "q0.sample.ack"
#define ABC_SAMPLE_BEFORE_NAME "q0.sample.before.maps"
#define ABC_SAMPLE_AFTER_NAME "q0.sample.after.maps"
enum abc_sample_runtime_error {
  ABC_SAMPLE_RUNTIME_OK = 0,
  ABC_SAMPLE_RUNTIME_INIT = 101,
  ABC_SAMPLE_RUNTIME_PROVIDER = 102,
  ABC_SAMPLE_RUNTIME_MAPS = 103,
  ABC_SAMPLE_RUNTIME_IO = 104,
  ABC_SAMPLE_RUNTIME_ACK = 105,
  ABC_SAMPLE_RUNTIME_TIMEOUT = 106,
  ABC_SAMPLE_RUNTIME_CLOCK = 107,
  ABC_SAMPLE_RUNTIME_CONSUMED = 108,
  ABC_SAMPLE_RUNTIME_CLOSED = 109,
  ABC_SAMPLE_RUNTIME_EXCEPTION = 110
};
#ifdef __cplusplus
extern "C" {
#endif
/* Serialized calls only. Initialization and q0 may each be attempted once.
 * q0 always consumes its slot; close releases each owned descriptor once.
 * Time/size limits are post-call rejection bounds, not syscall preemption or
 * limits on GetHeapSample's temporary dynamic allocation peak. */
int abc_sample_runtime_initialize(void);
int abc_sample_runtime_q0(uint64_t gauge_dart_us);
int abc_sample_runtime_close(void);
/* Static NUL-terminated JSON, strictly shorter than ABC_SAMPLE_METADATA_CAP.
 * Valid until next call. Evidence only: never maps/full-run acceptance. */
const char *abc_sample_runtime_metadata_json(void);
#ifdef __cplusplus
}
#endif
#endif
