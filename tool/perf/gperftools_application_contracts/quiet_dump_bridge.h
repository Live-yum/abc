#ifndef ABC_QUIET_DUMP_BRIDGE_H
#define ABC_QUIET_DUMP_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#define ABC_QUIET_ABI 1u
#define ABC_MAP_CAP (1024u*1024u)
#define ABC_RECEIPT_CAP 512u
#define ABC_HOOK_NS UINT64_C(10000000000)
#define ABC_ACK_NS UINT64_C(2000000000)
enum abc_quiet_error {
    ABC_QUIET_OK=0, ABC_QUIET_BAD_INIT=1, ABC_QUIET_PROVIDER=2,
    ABC_QUIET_NOT_RUNNING=3, ABC_QUIET_CUT_ORDER=4, ABC_QUIET_MAPS=5,
    ABC_QUIET_IO=6, ABC_QUIET_ACK=7, ABC_QUIET_TIMEOUT=8,
    ABC_QUIET_STOP_FAILED=9, ABC_QUIET_CLOCK=10, ABC_QUIET_STOPPED=11
};
/* gauge_dart_us is Dart Timeline.timeSync's domain; other times below are
 * native CLOCK_MONOTONIC nanoseconds. Never subtract the two clock domains. */
struct abc_quiet_cut {
    int cycle, accepted;
    uint64_t gauge_dart_us, enter_ns, dump_start_ns, dump_end_ns, ack_end_ns, exit_ns;
    size_t maps_before_size, maps_after_size;
};
struct abc_quiet_metadata {
    unsigned abi, offline, slots_used, dump_count, stop_calls;
    int initialized, failure, stop_requested, stop_verified, cleanup_failure;
    uint64_t observer_preallocated_bytes, stop_start_ns, stop_end_ns;
    uint64_t observer_maps_bytes;
    unsigned observer_held_fds, observer_closed_fds, observer_fd_close_attempts;
    int observer_fd_cleanup_failure;
    struct abc_quiet_cut cuts[2];
};
/* No callback may start a profiler or add a dump. map_read must detect EOF
 * beyond cap. publish uses O_EXCL and is called only after Dump returned.
 * wait_ack must enforce its absolute native deadline and exact receipt slot.
 * These calls can block: the independent supervisor owns the hard deadline. */
struct abc_quiet_ops {
    void *user;
    uint64_t (*clock_ns)(void *);
    int (*provider_matches)(void *);
    int (*running)(void *);
    void (*dump)(void *,const char *);
    void (*stop)(void *);
    int (*map_read)(void *,char *,size_t,size_t *);
    int (*publish)(void *,unsigned,const struct abc_quiet_cut *,const char *,const char *);
    int (*wait_ack)(void *,unsigned,int,uint64_t);
};
struct abc_quiet_context {
    struct abc_quiet_ops ops;
    struct abc_quiet_metadata meta;
    char maps_before[ABC_MAP_CAP], maps_after[ABC_MAP_CAP];
};
int abc_quiet_core_init(struct abc_quiet_context *,const struct abc_quiet_ops *,unsigned offline);
int abc_quiet_core_after_gauge(struct abc_quiet_context *,int cycle,uint64_t gauge_dart_us);
int abc_quiet_core_stop(struct abc_quiet_context *);
/* Linux adapter entrypoints for ordinary synchronous Dart FFI (not leaf).
 * Compile adapter with the same sealed header as launcher. */
unsigned abc_quiet_abi(void);
int abc_quiet_initialize(void);
int abc_quiet_after_gauge(int cycle,uint64_t gauge_dart_us);
int abc_quiet_stop(void);
const struct abc_quiet_metadata *abc_quiet_metadata(void);
#endif
