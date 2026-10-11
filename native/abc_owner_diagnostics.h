/* Separate, optional diagnostic ABI. Not present in ordinary product builds. */
#ifndef ABC_OWNER_DIAGNOSTICS_H
#define ABC_OWNER_DIAGNOSTICS_H
#include "abc_engine.h"
#include <stddef.h>
#include <stdint.h>
#define ABC_OWNER_DIAGNOSTICS_ABI 1u
#define ABC_OWNER_DIAGNOSTICS_WORDS 16u
enum AbcOwnerDiagnosticWord {
    ABC_OWNER_ABI = 0, ABC_OWNER_WORDS = 1,
    ABC_OWNER_TOTAL_BYTES = 2, ABC_OWNER_NATIVE_BYTES = 3,
    ABC_OWNER_BRIDGE_BYTES = 4, ABC_OWNER_PEAK_BYTES = 5,
    ABC_OWNER_WORLD_COUNT = 6, ABC_OWNER_STREAM_PRESENT = 7,
    ABC_OWNER_CHECKPOINT_ACTIVE = 8, ABC_OWNER_CIRCUIT_COUNT = 9,
    ABC_OWNER_VM_COUNT = 10, ABC_OWNER_CENSORED_MASK = 11
};
/* Call only on the established owning thread, between complete serialized calls.
 * All payload counters are UINT32-saturated; mask bits 0..3 correspond to words
 * 2..5 equal to UINT32_MAX and must be treated as censored, not exact values.
 * Words 12..15 are reserved zero. No pointers or resource paths are returned. */
#ifdef __cplusplus
extern "C" {
#endif
ABC_EXPORT uint32_t abc_owner_diagnostics_abi_version(void);
/* Returns 0; invalid output/count returns -1 without writing to output.
 * Caller supplies aligned space for exactly 16 uint64_t words. No allocation,
 * freeing, lifecycle mutation, reset, or synchronization is performed. */
ABC_EXPORT int32_t abc_owner_diagnostics_snapshot_v1(uint64_t* out, size_t words);
#ifdef __cplusplus
}
#endif
#endif
