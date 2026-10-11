/* Built exclusively when ABC_OWNER_DIAGNOSTICS and ABC_PERF_COUNTERS are ON. */
#include "abc_owner_diagnostics.h"
#include <limits.h>
#ifndef ABC_OWNER_DIAGNOSTICS
#error "Owner diagnostics must be explicitly enabled"
#endif
extern uint32_t tx_heap_used(void);
extern uint32_t tx_native_heap_used(void);
extern uint32_t tx_bridge_heap_used(void);
extern uint32_t tx_heap_peak(void);
extern uint32_t tx_get_world_open_count(void);
extern int tx_stream_has_task(void);
extern int tx_checkpoint_active(void);
/* Hidden, bounded four-slot census; low 32 bits owners, high 32 bits VMs. */
extern uint64_t cx_owner_diagnostics_counts(void);

uint32_t abc_owner_diagnostics_abi_version(void) {
    return ABC_OWNER_DIAGNOSTICS_ABI;
}
int32_t abc_owner_diagnostics_snapshot_v1(uint64_t* out, size_t words) {
    if (!out || words != ABC_OWNER_DIAGNOSTICS_WORDS) return -1;
    const uint64_t counts = cx_owner_diagnostics_counts();
    uint64_t values[ABC_OWNER_DIAGNOSTICS_WORDS] = {0};
    values[ABC_OWNER_ABI] = ABC_OWNER_DIAGNOSTICS_ABI;
    values[ABC_OWNER_WORDS] = ABC_OWNER_DIAGNOSTICS_WORDS;
    values[ABC_OWNER_TOTAL_BYTES] = tx_heap_used();
    values[ABC_OWNER_NATIVE_BYTES] = tx_native_heap_used();
    values[ABC_OWNER_BRIDGE_BYTES] = tx_bridge_heap_used();
    values[ABC_OWNER_PEAK_BYTES] = tx_heap_peak();
    values[ABC_OWNER_WORLD_COUNT] = tx_get_world_open_count();
    values[ABC_OWNER_STREAM_PRESENT] = tx_stream_has_task() != 0;
    values[ABC_OWNER_CHECKPOINT_ACTIVE] = tx_checkpoint_active() != 0;
    values[ABC_OWNER_CIRCUIT_COUNT] = (uint32_t)counts;
    values[ABC_OWNER_VM_COUNT] = (uint32_t)(counts >> 32);
    for (uint32_t i = 0; i < 4; ++i) {
        if (values[ABC_OWNER_TOTAL_BYTES + i] == UINT32_MAX)
            values[ABC_OWNER_CENSORED_MASK] |= (uint64_t)1 << i;
    }
    for (size_t i = 0; i < ABC_OWNER_DIAGNOSTICS_WORDS; ++i) out[i] = values[i];
    return 0;
}
