/* Optional test-only telemetry; no allocation, lifecycle or runtime behavior
 * changes. Read only between completed serialized engine calls. Not included
 * in production builds unless ABC_PERF_COUNTERS is explicitly enabled.
 * Counters saturate at UINT32_MAX. Native includes persistent tx roots, while
 * libc/QuickJS allocations and allocator headers are outside these counters. */
#include "abc_engine.h"
extern uint32_t tx_heap_used(void);
extern uint32_t tx_native_heap_used(void);
extern uint32_t tx_bridge_heap_used(void);
extern uint32_t tx_heap_peak(void);
extern uint32_t tx_get_world_open_count(void);

ABC_EXPORT uint32_t abc_perf_abi_version(void) { return 1; }
ABC_EXPORT uint32_t abc_perf_total_live_bytes(void) { return tx_heap_used(); }
ABC_EXPORT uint32_t abc_perf_native_live_bytes(void) { return tx_native_heap_used(); }
ABC_EXPORT uint32_t abc_perf_bridge_live_bytes(void) { return tx_bridge_heap_used(); }
ABC_EXPORT uint32_t abc_perf_peak_bytes(void) { return tx_heap_peak(); }
ABC_EXPORT uint32_t abc_perf_world_open_count(void) { return tx_get_world_open_count(); }
#define ABC_PERF_STRINGIFY1(x) #x
#define ABC_PERF_STRINGIFY(x) ABC_PERF_STRINGIFY1(x)
ABC_EXPORT const char* abc_perf_compiler(void) {
#if defined(__VERSION__)
    return __VERSION__;
#elif defined(_MSC_VER)
    return "MSVC " ABC_PERF_STRINGIFY(_MSC_VER);
#else
    return "unknown";
#endif
}
