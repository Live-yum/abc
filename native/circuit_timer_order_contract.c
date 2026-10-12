/* Original private-adapter contracts. Including the production module lets this
 * test inspect bounded cache state without extending the public world ABI.
 * Link against terrax_world_static.a as for the other native contracts: its
 * timer-order object is not extracted because this translation unit defines it.
 * Full WLD/VM rollback coverage lives in tool/test_timer_fifo.py. */
#include "terra_circuit_world_internal.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "terra_circuit_timer_order.c"

static void setup(CxWorld* w, uint32_t timers, uint32_t extra_sources) {
    memset(w, 0, sizeof(*w));
    w->maximum = 16u * 1024u * 1024u;
    w->width = timers + extra_sources + 12u;
    w->height = 20;
    w->phase = CX_IDLE;
    w->devices = calloc(timers, sizeof(CxDevice));
    w->device_count = timers;
    w->mechs = calloc(999, sizeof(uint32_t));
    w->mech_capacity = 999;
    assert(w->devices && w->mechs);
    for (uint32_t i = 0; i < timers; i++) {
        CxDevice* d = w->devices + i;
        d->x = 5 + i;
        d->y = 10;
        d->tile.active = 1;
        d->tile.type = 144;
        d->nets[0] = 1;
    }
    cx_timer_order_prepare(w);
    assert(w->timer_order);
    TxTile column[20] = {0};
    w->column = column;
    for (uint32_t x = 5; x <= timers + 5u + extra_sources; x++) {
        w->x = x;
        cx_timer_order_cell(w, 10, 0, 1, 1, 1, 0);
    }
    cx_timer_order_finish(w);
    w->column = NULL;
    assert(w->timer_order->count == timers + extra_sources + 1u);
}

static void clear_owner_state(CxWorld* w) {
    w->mech_count = 0;
    for (uint32_t i = 0; i < w->device_count; i++) {
        w->devices[i].tile.frame_y = 0;
        w->devices[i].cooldown = 0;
        w->devices[i].wire_hit_mask = 0;
    }
}

static void start(CxWorld* w, uint32_t source) {
    w->seed_x = source;
    w->seed_y = 10;
    w->seed_width = w->seed_height = 1;
    cx_timer_order_begin(w);
    for (uint32_t i = 0; i < w->device_count; i++)
        cx_timer_order_hit(w, w->devices + i, 0, 1);
}

static void finish(CxWorld* w) {
    int status;
    uint32_t steps = 0;
    do {
        status = cx_timer_order_step(w);
        assert(status >= 0 && ++steps < 100000);
    } while (status);
    assert(!w->timer_hit_events);
}

static int cached(const CxWorld* w, uint32_t source) {
    for (uint32_t i = 0; i < ORDER_CACHES; i++)
        if (w->timer_order->cache[i].valid &&
            w->timer_order->cache[i].x == source) return 1;
    return 0;
}

static void destroy(CxWorld* w) {
    cx_timer_order_free(w);
    assert(w->bytes == 0);
    free(w->devices);
    free(w->mechs);
}

static void cache_overflow(void) {
    CxWorld w;
    setup(&w, 4101, 0);
    for (uint32_t round = 0; round < 2; round++) {
        clear_owner_state(&w);
        start(&w, 4106);
        finish(&w);
        assert(w.mech_count == 999);
        for (uint32_t i = 0; i < 999; i++) assert(w.mechs[i] == 4100 - i);
        for (uint32_t i = 0; i < 4101; i++)
            assert(w.devices[i].tile.frame_y == 18);
        /* Every hit applies after the 4096-entry cache limit; this source must
         * remain uncached so a later repeat cannot replay a truncated trace. */
        assert(!cached(&w, 4106));
    }
    destroy(&w);
}

static void lru_and_partial_replay(void) {
    CxWorld w;
    setup(&w, 2, 20);
    for (uint32_t x = 7; x < 23; x++) {
        clear_owner_state(&w);
        start(&w, x);
        finish(&w);
        assert(cached(&w, x));
    }
    assert(cached(&w, 7) && cached(&w, 8));
    clear_owner_state(&w);
    start(&w, 7);
    finish(&w);
    clear_owner_state(&w);
    start(&w, 23);
    finish(&w);
    assert(cached(&w, 7) && !cached(&w, 8) && cached(&w, 23));

    /* Restore owner state after the first timer changes in a cold replay. The
     * next TripWire must discard its unfinished cache and restart traversal. */
    clear_owner_state(&w);
    start(&w, 24);
    for (uint32_t n = 0; !w.mech_count; n++) {
        assert(n < 1000 && cx_timer_order_step(&w) > 0);
    }
    assert(w.mech_count == 1 && !cached(&w, 24));
    clear_owner_state(&w);
    start(&w, 24);
    finish(&w);
    assert(w.mech_count == 2 && w.mechs[0] == 1 && w.mechs[1] == 0);
    assert(cached(&w, 24));

    /* An already-complete cached trace also survives a partial replay restart. */
    clear_owner_state(&w);
    start(&w, 24);
    for (uint32_t n = 0; !w.mech_count; n++) {
        assert(n < 1000 && cx_timer_order_step(&w) > 0);
    }
    assert(w.mech_count == 1);
    clear_owner_state(&w);
    start(&w, 24);
    finish(&w);
    assert(w.mech_count == 2 && w.mechs[0] == 1 && w.mechs[1] == 0);
    destroy(&w);
}

static int32_t next_candidate(void* context, uint32_t net, uint32_t* cursor,
                              TerraVmGateRef* out) {
    (void)context;
    (void)net;
    if (*cursor == 100) return 0;
    *out = (TerraVmGateRef){0, ++*cursor};
    return 1;
}

static int32_t evaluate(void* context, TerraVmGateRef event,
                        const TerraCircuitVm* vm, TerraVmGateResult* out) {
    (void)context;
    (void)event;
    (void)vm;
    (void)out;
    return 0;
}

static void active_owner_budget(void) {
    CxWorld w = {0};
    w.maximum = 8192;
    w.phase = CX_RUN;
    TerraVmCallbacks callbacks = {0};
    callbacks.next_candidate = next_candidate;
    callbacks.evaluate = evaluate;
    assert(terra_vm_create(1, w.maximum, &callbacks, &w, &w.vm) == TERRA_VM_OK);
    uint32_t seed = 0;
    assert(terra_vm_begin(w.vm, &seed, 1) == TERRA_VM_MORE);
    /* Stop after NET_SELECT, when the seed and seen-net arrays exist and the
     * next transition will grow the candidate array for the first time. */
    assert(terra_vm_step(w.vm, 3) == TERRA_VM_MORE);
    assert(terra_vm_parity(w.vm, 0) == 1);
    TerraVmStats stats;
    terra_vm_stats(w.vm, &stats);
    assert(stats.active && !stats.queued_candidates);
    void* owner = cx_optional_alloc(&w, w.maximum - stats.allocated_bytes - 256u);
    assert(owner);
    /* The owner allocation must lower the active VM's budget. Otherwise this
     * candidate growth would succeed by spending the same memory twice. */
    assert(terra_vm_step(w.vm, 1) == TERRA_VM_LIMIT);
    terra_vm_stats(w.vm, &stats);
    assert(!stats.active && terra_vm_parity(w.vm, 0) == 0);
    assert(w.bytes + stats.allocated_bytes <= w.maximum);
    cx_free(&w, owner);
    assert(w.bytes == 0);
    assert(terra_vm_set_budget(w.vm, cx_vm_available(&w)) == TERRA_VM_OK);
    assert(terra_vm_begin(w.vm, &seed, 1) == TERRA_VM_MORE);
    int status;
    do { status = terra_vm_step(w.vm, 1); } while (status == TERRA_VM_MORE);
    assert(status == TERRA_VM_OK && terra_vm_parity(w.vm, 0) == 1);
    terra_vm_stats(w.vm, &stats);
    assert(stats.gates_evaluated == 100);
    terra_vm_destroy(w.vm);
}

static void optional_compile_eviction(void) {
    CxWorld w;
    const uint32_t phases[] = {CX_INTERN, CX_QUERY};
    for (uint32_t i = 0; i < 2; i++) {
        setup(&w, 2, 0);
        w.phase = phases[i];
        w.maximum = w.bytes + 32u;
        w.operation_active = 1;
        assert(!cx_alloc(&w, 64u) && w.timer_order);
        w.operation_active = 0;
        w.error = 0;
        void* mandatory = cx_alloc(&w, 64u);
        assert(mandatory && !w.timer_order && !w.error);
        assert(w.bytes <= w.maximum);
        cx_free(&w, mandatory);
        destroy(&w);
    }

    /* An active VM protects its traversal even when the outer operation flag
     * is clear and the caller's phase happens to look like an idle query. */
    setup(&w, 2, 0);
    w.phase = CX_QUERY;
    TerraVmCallbacks callbacks = {0};
    callbacks.next_candidate = next_candidate;
    callbacks.evaluate = evaluate;
    assert(terra_vm_create(1, cx_vm_available(&w), &callbacks, &w, &w.vm) == 0);
    uint32_t seed = 0;
    assert(terra_vm_begin(w.vm, &seed, 1) == TERRA_VM_MORE);
    assert(cx_operation_begin(&w) == TCW_STATE && w.timer_order);
    TerraVmStats stats;
    terra_vm_stats(w.vm, &stats);
    w.maximum = w.bytes + stats.allocated_bytes + 32u;
    assert(!cx_alloc(&w, 64u) && w.timer_order && !w.operation_active);
    terra_vm_cancel(w.vm);
    w.error = 0;
    void* mandatory = cx_alloc(&w, 64u);
    assert(mandatory && !w.timer_order && !w.error);
    terra_vm_destroy(w.vm);
    w.vm = NULL;
    cx_free(&w, mandatory);
    destroy(&w);

    /* Exercise the exact-zero headroom boundary: the final mandatory snapshot
     * fits, but VM creation must first evict the optional graph to make room. */
    setup(&w, 2, 0);
    uint32_t before = w.bytes;
    void* probe = cx_alloc(&w, 1u);
    assert(probe);
    uint32_t snapshot_charge = w.bytes - before;
    cx_free(&w, probe);
    w.maximum = w.bytes + snapshot_charge;
    w.phase = CX_INTERN;
    TxWorld source = {0};
    w.world = &source;
    w.networks = 1;
    assert(cx_create_vm(&w) == TCW_OK && w.vm && !w.timer_order && !w.error);
    terra_vm_stats(w.vm, &stats);
    assert(w.bytes + stats.allocated_bytes <= w.maximum);
    terra_vm_destroy(w.vm);
    w.vm = NULL;
    cx_free(&w, w.general_snapshot);
    destroy(&w);
}

int main(void) {
    cache_overflow();
    lru_and_partial_replay();
    active_owner_budget();
    optional_compile_eviction();
    puts("PASS: timer cache overflow, 999 FIFO cap, LRU eviction, partial replay "
         "restart, active VM/owner budget rollback and retry, compile eviction");
    return 0;
}
