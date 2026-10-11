/* Private viewport-cache allocation/ownership contracts, not a benchmark.
 * Include the production modules to inspect exact allocator/VM boundaries,
 * following circuit_timer_order_contract.c. Link terrax_world_static.a with
 * -Wl,--wrap=tx_persistent_alloc,--wrap=tx_persistent_free -lz -lm.
 * No production failure-injection hooks or public ABI additions are needed. */
#include "terra_circuit_world_internal.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "terra_circuit_vm.c"
#include "terra_circuit_world.c"
#include "terra_circuit_timer_order.c"
#include "terra_circuit_query.c"

extern uint8_t* __real_tx_persistent_alloc(uint32_t);
extern void __real_tx_persistent_free(void*);
static void* live_allocations[4096];
static uint32_t live_count, allocation_attempts, failures_left, failures_seen;

uint8_t* __wrap_tx_persistent_alloc(uint32_t bytes) {
    ++allocation_attempts;
    if (failures_left) { --failures_left; ++failures_seen; return NULL; }
    uint8_t* p = __real_tx_persistent_alloc(bytes);
    if (p) {
        assert(live_count < sizeof(live_allocations) / sizeof(*live_allocations));
        live_allocations[live_count++] = p;
    }
    return p;
}

void __wrap_tx_persistent_free(void* p) {
    if (!p) return;
    uint32_t i = 0;
    while (i < live_count && live_allocations[i] != p) ++i;
    assert(i < live_count); /* Includes double-free detection. */
    live_allocations[i] = live_allocations[--live_count];
    __real_tx_persistent_free(p);
}

typedef struct Run {
    CxWorld w;
    uint32_t next_calls, evaluate_calls, begins, commits, rollbacks, reclaims;
} Run;

static int32_t candidates(void* context, uint32_t net, uint32_t* cursor,
                          TerraVmGateRef* out) {
    Run* r = context;
    ++r->next_calls;
    if (net || *cursor == 100u) return 0;
    *out = (TerraVmGateRef){0, ++*cursor};
    return 1;
}

static int32_t evaluate_gate(void* context, TerraVmGateRef event,
                             const TerraCircuitVm* vm, TerraVmGateResult* out) {
    Run* r = context;
    (void)vm;
    ++r->evaluate_calls;
    out->identity = event;
    out->count = 1;
    out->nets[0] = 1;
    return 1;
}
static int32_t begin_transaction(void* context) {
    ++((Run*)context)->begins;
    return 0;
}
static void commit_transaction(void* context) { ++((Run*)context)->commits; }
static void rollback_transaction(void* context) { ++((Run*)context)->rollbacks; }
static int reclaim_viewport(void* context) {
    Run* r = context;
    ++r->reclaims;
    return cx_viewport_cache_reclaim(&r->w);
}

static void check_budget(const CxWorld* w) {
    TerraVmStats s;
    terra_vm_stats(w->vm, &s);
    assert((uint64_t)w->bytes + s.allocated_bytes <= w->maximum);
    if (w->vm) assert(w->vm->maximum == w->maximum - w->bytes);
}

static void run_setup(Run* r) {
    memset(r, 0, sizeof(*r));
    r->w.maximum = 2u * 1024u * 1024u;
    r->w.phase = CX_RUN;
    TerraVmCallbacks cb = {0};
    cb.next_candidate = candidates;
    cb.evaluate = evaluate_gate;
    cb.transaction_begin = begin_transaction;
    cb.transaction_commit = commit_transaction;
    cb.transaction_rollback = rollback_transaction;
    assert(terra_vm_create(2, r->w.maximum, &cb, r, &r->w.vm) == 0);
    cx_vm_set_reclaim(r->w.vm, reclaim_viewport, r);
}

static uint32_t install_viewport(CxWorld* w) {
    assert(!w->viewport_cells);
    uint32_t before = w->bytes;
    w->viewport_cells = cx_optional_alloc(w, CX_VIEWPORT_CELLS * sizeof(CxViewportCell));
    assert(w->viewport_cells);
    memset(w->viewport_cells, 0xa5, CX_VIEWPORT_CELLS * sizeof(CxViewportCell));
    w->viewport_valid = 1;
    assert(w->bytes - before == CX_VIEWPORT_CELLS * sizeof(CxViewportCell) + sizeof(CxAllocation) + 32u);
    check_budget(w);
    return w->bytes - before;
}

static void run_cleanup(Run* r) {
    cx_viewport_cache_cancel(&r->w);
    cx_timer_order_free(&r->w);
    terra_vm_destroy(r->w.vm);
    r->w.vm = NULL;
    assert(r->w.bytes == 0);
}

static void begin_pulse(Run* r) {
    uint32_t seed = 0;
    assert(terra_vm_begin(r->w.vm, &seed, 1) == TERRA_VM_MORE);
}

static void equal_progress(const Run* a, const Run* b) {
    TerraVmStats x, y;
    terra_vm_stats(a->w.vm, &x);
    terra_vm_stats(b->w.vm, &y);
    assert(x.net_pulses == y.net_pulses && x.gates_evaluated == y.gates_evaluated);
    assert(x.gates_fired == y.gates_fired && x.smoke_events == y.smoke_events);
    assert(x.completed_pulses == y.completed_pulses && x.operations == y.operations);
    assert(x.active == y.active && x.queued_candidates == y.queued_candidates);
    assert(x.queued_gates == y.queued_gates && x.allocated_bytes == y.allocated_bytes);
    assert(a->next_calls == b->next_calls && a->evaluate_calls == b->evaluate_calls);
    assert(a->begins == b->begins && a->commits == b->commits && a->rollbacks == b->rollbacks);
    for (uint32_t n = 0; n < 2; ++n) assert(terra_vm_parity(a->w.vm, n) == terra_vm_parity(b->w.vm, n));
}

enum Growth { CANDIDATE_FIRST, CANDIDATE_GROW, GATE_QUEUE_FIRST, DONE_FIRST, DONE_GROW };
static int at_growth(const TerraCircuitVm* vm, enum Growth growth) {
    switch (growth) {
    case CANDIDATE_FIRST: return vm->phase == VM_NET_CANDIDATES && !vm->candidate_capacity;
    case CANDIDATE_GROW: return vm->phase == VM_NET_CANDIDATES && vm->candidate_count == 64u;
    case GATE_QUEUE_FIRST: return vm->phase == VM_EVALUATE && !vm->next_capacity;
    case DONE_FIRST: return vm->phase == VM_GATES && !vm->done_capacity;
    case DONE_GROW: return vm->phase == VM_GATES && vm->done_count == 47u;
    }
    return 0;
}

/* The only difference is optional ROI ownership. Both VMs execute each
 * transition exactly once, and compare counters/callbacks/parity after EVERY
 * step, including the step whose allocator reclaims the slab. */
static void active_growth(enum Growth growth, int inject_oom) {
    uint32_t live_before = live_count;
    Run cached, reference;
    run_setup(&cached);
    run_setup(&reference);
    begin_pulse(&cached);
    begin_pulse(&reference);
    for (uint32_t n = 0; !at_growth(cached.w.vm, growth); ++n) {
        assert(n < 10000u);
        assert(terra_vm_step(cached.w.vm, 1) == TERRA_VM_MORE);
        assert(terra_vm_step(reference.w.vm, 1) == TERRA_VM_MORE);
        equal_progress(&cached, &reference);
    }
    uint32_t charge = install_viewport(&cached.w);
    uint32_t maximum = cached.w.bytes + cached.w.vm->allocated + (inject_oom ? 65536u : 32u);
    cached.w.maximum = reference.w.maximum = maximum;
    assert(terra_vm_set_owner_budget(cached.w.vm, cx_vm_available(&cached.w)) == 0);
    assert(terra_vm_set_owner_budget(reference.w.vm, cx_vm_available(&reference.w)) == 0);
    assert(cached.w.vm->active && charge > 65536u);
    uint32_t attempts = allocation_attempts, failures = failures_seen;
    if (inject_oom) failures_left = 1;
    assert(terra_vm_step(cached.w.vm, 1) == TERRA_VM_MORE);
    assert(!failures_left && !cached.w.viewport_cells && !cached.w.viewport_valid);
    assert(cached.reclaims == 1 && cached.w.maximum == maximum);
    assert(allocation_attempts - attempts == (inject_oom ? 2u : 1u));
    assert(failures_seen - failures == (inject_oom ? 1u : 0u));
    assert(terra_vm_step(reference.w.vm, 1) == TERRA_VM_MORE);
    equal_progress(&cached, &reference);
    int status;
    uint32_t steps = 0;
    do {
        status = terra_vm_step(cached.w.vm, 1);
        assert(status == terra_vm_step(reference.w.vm, 1));
        assert(status >= 0 && ++steps < 10000u);
        assert(cached.w.maximum == maximum && reference.w.maximum == maximum);
        equal_progress(&cached, &reference);
        check_budget(&cached.w);
        check_budget(&reference.w);
    } while (status == TERRA_VM_MORE);
    assert(cached.begins == 1 && cached.commits == 1 && !cached.rollbacks);
    assert(cached.evaluate_calls == 100 && cached.w.vm->counters.gates_fired == 100);
    run_cleanup(&cached);
    run_cleanup(&reference);
    assert(live_count == live_before);
}

static void pinned_and_refusal(void) {
    Run r;
    run_setup(&r);
    install_viewport(&r.w);
    CxViewportCell* slab = r.w.viewport_cells;
    uint32_t before = r.w.bytes;
    r.w.viewport_pinned = r.w.viewport_building = r.w.viewport_hit = r.w.viewport_probe = 1;
    assert(!cx_viewport_cache_reclaim(&r.w));
    assert(r.w.viewport_cells == slab && r.w.bytes == before);
    r.w.maximum = r.w.bytes + r.w.vm->allocated;
    assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
    assert(!cx_optional_alloc(&r.w, 1) && !r.w.error);
    assert(!cx_optional_alloc(&r.w, UINT32_MAX) && !r.w.error);
    assert(r.w.viewport_cells == slab && r.w.viewport_valid);
    cx_viewport_cache_cancel(&r.w);
    assert(!r.w.viewport_cells && !r.w.viewport_pinned && !r.w.viewport_valid);
    assert(!r.w.viewport_hit && !r.w.viewport_building && !r.w.viewport_probe);
    assert(!r.w.bytes && !cx_viewport_cache_reclaim(&r.w));
    check_budget(&r.w);
    run_cleanup(&r);
}

static void owner_pressure(int optional, int inject_oom) {
    Run r;
    run_setup(&r);
    begin_pulse(&r);
    assert(terra_vm_step(r.w.vm, 3) == TERRA_VM_MORE);
    install_viewport(&r.w);
    uint32_t maximum = r.w.bytes + r.w.vm->allocated + (inject_oom ? 65536u : 32u);
    r.w.maximum = maximum;
    assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
    uint64_t operations = r.w.vm->counters.operations;
    uint32_t attempts = allocation_attempts;
    if (inject_oom) failures_left = 1;
    void* owner = optional ? cx_optional_alloc(&r.w, 1024u) : cx_alloc(&r.w, 1024u);
    assert(owner && !r.w.error && !r.w.viewport_cells && !failures_left);
    assert(allocation_attempts - attempts == (inject_oom ? 2u : 1u));
    assert(r.w.maximum == maximum && r.w.vm->active);
    assert(r.w.vm->counters.operations == operations && terra_vm_parity(r.w.vm, 0) == 1);
    check_budget(&r.w);
    cx_free(&r.w, owner);
    assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
    int status;
    do { status = terra_vm_step(r.w.vm, 1); check_budget(&r.w); } while (status == TERRA_VM_MORE);
    assert(status == TERRA_VM_OK && r.begins == 1 && r.commits == 1 && !r.rollbacks);
    run_cleanup(&r);
}

static void terminal_failures(void) {
    Run r;
    run_setup(&r);
    begin_pulse(&r);
    assert(terra_vm_step(r.w.vm, 3) == TERRA_VM_MORE);
    install_viewport(&r.w);
    uint32_t maximum = r.w.maximum, attempts = allocation_attempts;
    failures_left = 2;
    assert(terra_vm_step(r.w.vm, 1) == TERRA_VM_OOM);
    assert(allocation_attempts == attempts + 2u && !failures_left && r.reclaims == 1);
    assert(!r.w.viewport_cells && !r.w.vm->active && r.w.maximum == maximum);
    assert(r.begins == 1 && !r.commits && r.rollbacks == 1);
    assert(r.next_calls == 1 && !r.evaluate_calls && terra_vm_parity(r.w.vm, 0) == 0);
    check_budget(&r.w);
    run_cleanup(&r);

    run_setup(&r);
    install_viewport(&r.w);
    CxViewportCell* slab = r.w.viewport_cells;
    attempts = allocation_attempts;
    assert(!vm_allocate(r.w.vm, UINT32_MAX));
    assert(r.w.vm->allocation_error == TERRA_VM_LIMIT && !r.reclaims);
    assert(r.w.viewport_cells == slab && allocation_attempts == attempts);
    uint32_t requested = r.w.bytes + 1024u;
    maximum = r.w.maximum = r.w.bytes + r.w.vm->allocated;
    assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
    assert(!vm_allocate(r.w.vm, requested));
    assert(r.w.vm->allocation_error == TERRA_VM_LIMIT && r.reclaims == 1);
    assert(!r.w.viewport_cells && r.w.maximum == maximum && allocation_attempts == attempts);
    run_cleanup(&r);

    /* Even a VM pressure callback cannot free an in-use query slab. The
     * synthetic concurrent state exercises the defensive ownership check. */
    run_setup(&r);
    begin_pulse(&r);
    assert(terra_vm_step(r.w.vm, 3) == TERRA_VM_MORE);
    install_viewport(&r.w);
    slab = r.w.viewport_cells;
    r.w.viewport_pinned = 1;
    maximum = r.w.maximum = r.w.bytes + r.w.vm->allocated;
    assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
    attempts = allocation_attempts;
    assert(terra_vm_step(r.w.vm, 1) == TERRA_VM_LIMIT);
    assert(r.reclaims == 1 && r.w.viewport_cells == slab && r.w.viewport_pinned);
    assert(allocation_attempts == attempts && r.w.maximum == maximum);
    assert(r.begins == 1 && r.rollbacks == 1 && !r.commits);
    run_cleanup(&r);

    for (int optional = 0; optional < 2; ++optional) {
        run_setup(&r);
        install_viewport(&r.w);
        maximum = r.w.maximum;
        failures_left = 2; attempts = allocation_attempts;
        void* needed = optional ? cx_optional_alloc(&r.w, 32u) : cx_alloc(&r.w, 32u);
        assert(!needed && !failures_left && allocation_attempts == attempts + 2u);
        assert(!r.w.viewport_cells && r.w.maximum == maximum);
        assert(r.w.error == (optional ? 0u : (uint32_t)-TCW_MEMORY));
        check_budget(&r.w);
        run_cleanup(&r);
    }
}

static void production_registration(void) {
    CxWorld w = {0};
    TxWorld source = {0};
    w.maximum = 2u * 1024u * 1024u;
    w.phase = CX_INTERN; w.world = &source; w.networks = 2;
    assert(cx_create_vm(&w) == 0 && w.vm);
    assert(w.vm->owner_reclaim && w.vm->owner_reclaim_context == &w);
    install_viewport(&w);
    uint32_t maximum = w.maximum = w.bytes + w.vm->allocated;
    assert(terra_vm_set_owner_budget(w.vm, cx_vm_available(&w)) == 0);
    void* needed = vm_allocate(w.vm, 1024u);
    assert(needed && !w.viewport_cells && w.maximum == maximum);
    check_budget(&w);
    vm_release(w.vm, needed);
    terra_vm_destroy(w.vm); w.vm = NULL;
    cx_free(&w, w.general_snapshot);
    assert(!w.bytes);
}

static void binding_and_override_pressure(void) {
    for (uint32_t kind = 0; kind < 3; ++kind) {
        Run r;
        run_setup(&r);
        install_viewport(&r.w);
        uint32_t maximum = r.w.maximum = r.w.bytes + r.w.vm->allocated + 32u;
        assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
        TxTile column[1] = {{0}};
        uint32_t nets[4] = {0};
        if (!kind) {
            r.w.height = 1; r.w.column = column;
            r.w.seed_ids = r.w.opposite_ids = nets;
            assert(bind_point(&r.w, 0));
            check_budget(&r.w);
            cx_free(&r.w, r.w.bindings);
        } else if (kind == 1) {
            assert(cx_override_reserve(&r.w, 1) == 0 && r.w.overrides);
            check_budget(&r.w);
            cx_free(&r.w, r.w.overrides);
        } else {
            r.w.points = cx_alloc(&r.w, 128u * sizeof(CxInputPoint));
            assert(r.w.points);
            check_budget(&r.w);
            cx_free(&r.w, r.w.points);
        }
        assert(!r.w.viewport_cells && !r.w.error && r.w.maximum == maximum);
        run_cleanup(&r);
    }
}

static void query_setup(CxWorld* w) {
    memset(w, 0, sizeof(*w));
    w->maximum = 2u * 1024u * 1024u;
    w->width = 8192u; w->height = 2u; w->phase = CX_IDLE;
    w->front = cx_alloc(w, 8u * sizeof(uint32_t));
    w->checkpoint_index = cx_alloc(w, sizeof(CxCheckpoint));
    assert(w->front && w->checkpoint_index);
    memset(w->checkpoint_index, 0, sizeof(CxCheckpoint));
    const uint8_t checkpoint[] = {2, 0, 2, 0, 2, 0, 2, 0};
    assert(cx_bytes_append(w, &w->checkpoints, checkpoint, sizeof(checkpoint)));
    w->command.kind = TCW_VIEWPORT;
    w->command.width = 4096u; w->command.height = 1u; w->command.stride = 1u;
}

static void query_cleanup(CxWorld* w) {
    cx_viewport_cache_cancel(w);
    cx_free(w, w->result); cx_free(w, w->front); cx_free(w, w->checkpoint_index);
    cx_bytes_free(w, &w->checkpoints);
    assert(!w->bytes);
}

static void cap_and_result_priority(void) {
    assert(CX_VIEWPORT_CELLS == 4096u);
    CxWorld w;
    query_setup(&w);
    uint32_t before = w.bytes;
    assert(cx_query_begin(&w) == 0 && w.viewport_cells && w.viewport_pinned);
    uint32_t result_charge = 4096u * 16u + sizeof(CxAllocation) + 32u;
    uint32_t slab_charge = 4096u * sizeof(CxViewportCell) + sizeof(CxAllocation) + 32u;
    assert(w.bytes - before == result_charge + slab_charge);
    assert(w.result_capacity == 4096u && (void*)w.result != (void*)w.viewport_cells);
    cx_viewport_cache_cancel(&w);
    w.command.width = 4097u; w.command.stride = 4097u;
    assert(cx_query_begin(&w) == 0 && !w.viewport_cells && !w.error);
    /* Raw area, not sparse sampled output, controls admission. */
    w.command.width = 4096u; w.command.stride = 1u;
    w.maximum = w.bytes + slab_charge - 1u;
    uint32_t maximum = w.maximum;
    assert(cx_query_begin(&w) == 0 && !w.viewport_cells && !w.error);
    assert(w.maximum == maximum);
    ++w.maximum;
    assert(cx_query_begin(&w) == 0 && w.viewport_cells && w.bytes == w.maximum);
    cx_viewport_cache_cancel(&w);
    /* A larger mandatory result must reclaim an unpinned old ROI before any
     * selection or pinning. The new oversized query remains uncached. */
    w.maximum = 2u * 1024u * 1024u;
    install_viewport(&w);
    w.maximum = w.bytes + 32u;
    w.command.width = 4097u;
    assert(cx_query_begin(&w) == 0 && !w.viewport_cells && !w.error);
    assert(w.result_capacity == 4097u && w.bytes <= w.maximum);
    query_cleanup(&w);
}

static void replacement_and_result_ownership(void) {
    CxWorld w;
    query_setup(&w);
    assert(cx_query_begin(&w) == 0);
    CxViewportCell* slab = w.viewport_cells;
    uint32_t bytes = w.bytes, attempts = allocation_attempts;
    /* Restarting an incomplete same-key build cannot select a partial hit;
     * panning changes only metadata and reuses the one charged slab. */
    for (uint32_t i = 0; i < 128u; ++i) {
        w.command.x = i % 32u;
        w.command.width = 1u + i % 16u;
        w.viewport_count = 1;
        assert(cx_query_begin(&w) == 0);
        assert(w.viewport_cells == slab && w.viewport_building && w.viewport_pinned);
        assert(!w.viewport_hit && !w.viewport_valid && !w.viewport_count);
        assert(w.bytes == bytes && allocation_attempts == attempts);
    }
    w.command.x = 0; w.command.width = 2;
    assert(cx_query_begin(&w) == 0);
    memset(slab, 0, 2u * sizeof(*slab));
    slab[0].tile.type = 42; slab[1].tile.type = 43;
    w.viewport_count = 2; w.viewport_valid = 1;
    w.viewport_building = w.viewport_pinned = 0;
    assert(cx_query_begin(&w) == 0 && w.viewport_hit && w.viewport_pinned);
    uint32_t work = 1;
    assert(cx_query_step(&w, &work) == TCW_CONTINUE && !w.event.kind);
    assert(w.result_count == 1 && w.viewport_pinned && !cx_viewport_cache_reclaim(&w));
    work = 1;
    assert(cx_query_step(&w, &work) == TCW_CONTINUE && w.event.kind == TCW_RESULT);
    assert(!w.viewport_pinned && !w.viewport_hit && w.event.data_ptr == (uintptr_t)w.result);
    uint32_t expected[8];
    memcpy(expected, w.result, sizeof(expected));
    TerraCircuitWorldEvent event = w.event;
    assert(cx_viewport_cache_reclaim(&w) && !w.viewport_cells);
    assert(!memcmp(&event, &w.event, sizeof(event)));
    assert(!memcmp(expected, (const void*)w.event.data_ptr, sizeof(expected)));
    assert(expected[0] == 0 && expected[2] == 42 && expected[4] == 1 && expected[6] == 43);
    query_cleanup(&w);
}

static void streamed_probe_preserves_scan_state(void) {
    CxWorld w;
    query_setup(&w);
    w.command.width = 2;
    assert(cx_query_begin(&w) == 0);
    memset(w.viewport_cells, 0, 2u * sizeof(CxViewportCell));
    w.viewport_count = 2; w.viewport_valid = 1;
    w.viewport_building = w.viewport_pinned = 0;

    /* An earlier scan/scratch operation left a useful window, frontier and
     * page state. A warm-hit validation byte may not overwrite any of them. */
    uint8_t input[32], scratch[64], stored_pages[4];
    uint32_t ids[8], seed_ids[8], opposite_ids[8], cache_map[4];
    CxCachePage pages[2];
    TxTile column[2];
    memset(input, 0x39, sizeof(input)); memset(scratch, 0xa6, sizeof(scratch));
    memset(stored_pages, 0x81, sizeof(stored_pages));
    memset(ids, 0x12, sizeof(ids)); memset(seed_ids, 0x23, sizeof(seed_ids));
    memset(opposite_ids, 0x34, sizeof(opposite_ids));
    memset(cache_map, 0x45, sizeof(cache_map)); memset(pages, 0x56, sizeof(pages));
    memset(column, 0x67, sizeof(column)); memset(w.front, 0x78, 8u * sizeof(uint32_t));
    w.input = input; w.input_offset = 417; w.input_length = 27;
    w.cursor = 431; w.x = 47; w.y = 1; w.col_stage = 2; w.col_colour = 3; w.col_row = 1;
    w.column = column; w.ids = ids; w.seed_ids = seed_ids; w.opposite_ids = opposite_ids;
    w.map_cursor = 51; w.map_previous = 52; w.label_cursor = 53; w.gate_cursor = 54;
    w.up = 55; w.labels_count = 56; w.read_slot = 1;
    w.world_source = 17; w.tile_start = 101; w.tile_end = 501; w.world_size = 1024;
    w.scratch_source = 19; w.cache = scratch; w.cache_pages = pages;
    w.cache_map = cache_map; w.stored_pages = stored_pages;
    w.cache_count = 2; w.store_pages = 4; w.cache_clock = 59; w.flush_index = 1;
    w.store_size = 64; w.layout_code = 61; w.layout_member = 62;

    CxWorld original = w;
    uint8_t input_copy[sizeof(input)], scratch_copy[sizeof(scratch)];
    uint8_t stored_copy[sizeof(stored_pages)], pages_copy[sizeof(pages)], column_copy[sizeof(column)];
    uint32_t front_copy[8], ids_copy[8], seed_copy[8], opposite_copy[8], map_copy[4];
    memcpy(input_copy, input, sizeof(input)); memcpy(scratch_copy, scratch, sizeof(scratch));
    memcpy(stored_copy, stored_pages, sizeof(stored_pages)); memcpy(pages_copy, pages, sizeof(pages));
    memcpy(column_copy, column, sizeof(column)); memcpy(front_copy, w.front, sizeof(front_copy));
    memcpy(ids_copy, ids, sizeof(ids)); memcpy(seed_copy, seed_ids, sizeof(seed_ids));
    memcpy(opposite_copy, opposite_ids, sizeof(opposite_ids)); memcpy(map_copy, cache_map, sizeof(cache_map));

    assert(cx_query_begin(&w) == 0 && w.viewport_hit && w.viewport_pinned && w.viewport_probe == 1);
    uint32_t work = 1;
    assert(cx_query_step(&w, &work) == TCW_CONTINUE && !work);
    assert(w.event.kind == TCW_READ && w.event.source_id == 17);
    assert(w.event.offset == 101 && w.event.length == 1 && !w.result_count);
    assert(w.viewport_probe == 2 && w.viewport_pinned && w.read_target == CX_READ_VIEWPORT_PROBE);
    assert(!cx_viewport_cache_reclaim(&w));
    w.id = 0x1234567u;
    assert(!sessions[3]); sessions[3] = &w;
    CxWorld pending = w;
    uint8_t probe_byte = 0xff;
    assert(terra_circuit_world_supply(w.id, 18, 101, &probe_byte, 1) == TCW_INVALID);
    assert(!memcmp(&pending, &w, sizeof(w)));
    assert(terra_circuit_world_supply(w.id, 17, 102, &probe_byte, 1) == TCW_INVALID);
    assert(!memcmp(&pending, &w, sizeof(w)));
    assert(terra_circuit_world_supply(w.id, 17, 101, &probe_byte, 0) == TCW_INVALID);
    assert(!memcmp(&pending, &w, sizeof(w)));
    assert(terra_circuit_world_supply(w.id, 17, 101, &probe_byte, 1) == TCW_OK);
    pending.viewport_probe = pending.read_target = 0;
    memset(&pending.event, 0, sizeof(pending.event));
    assert(!memcmp(&pending, &w, sizeof(w))); /* Only probe/event state changed. */

#define SAME_SCAN(field) assert(w.field == original.field)
    SAME_SCAN(input_offset); SAME_SCAN(input_length); SAME_SCAN(cursor); SAME_SCAN(y);
    SAME_SCAN(col_stage); SAME_SCAN(col_colour); SAME_SCAN(col_row); SAME_SCAN(up);
    SAME_SCAN(map_cursor); SAME_SCAN(map_previous); SAME_SCAN(label_cursor); SAME_SCAN(gate_cursor);
    SAME_SCAN(labels_count); SAME_SCAN(read_slot); SAME_SCAN(scratch_source); SAME_SCAN(store_size);
    SAME_SCAN(cache_count); SAME_SCAN(store_pages); SAME_SCAN(cache_clock); SAME_SCAN(flush_index);
    SAME_SCAN(layout_code); SAME_SCAN(layout_member);
#undef SAME_SCAN
    assert(!memcmp(input_copy, input, sizeof(input)) && !memcmp(scratch_copy, scratch, sizeof(scratch)));
    assert(!memcmp(stored_copy, stored_pages, sizeof(stored_pages)) && !memcmp(pages_copy, pages, sizeof(pages)));
    assert(!memcmp(column_copy, column, sizeof(column)) && !memcmp(front_copy, w.front, sizeof(front_copy)));
    assert(!memcmp(ids_copy, ids, sizeof(ids)) && !memcmp(seed_copy, seed_ids, sizeof(seed_ids)));
    assert(!memcmp(opposite_copy, opposite_ids, sizeof(opposite_ids)) && !memcmp(map_copy, cache_map, sizeof(cache_map)));
    assert(w.viewport_pinned && !cx_viewport_cache_reclaim(&w));
    work = 2;
    assert(cx_query_step(&w, &work) == TCW_CONTINUE && w.event.kind == TCW_RESULT);
    assert(!w.viewport_pinned && cx_viewport_cache_reclaim(&w));
    assert(w.event.data_ptr == (uintptr_t)w.result && w.event.result_count == 2);
    sessions[3] = NULL;
    query_cleanup(&w);
}

static void optional_oom_and_destroy(void) {
    CxWorld w;
    query_setup(&w);
    assert(reserve_result(&w, 4096u) == 0);
    failures_left = 1;
    uint32_t attempts = allocation_attempts;
    assert(cx_query_begin(&w) == 0 && !w.viewport_cells && !w.error);
    assert(!failures_left && allocation_attempts == attempts + 1u);
    query_cleanup(&w);
    uint32_t live_before = live_count;
    for (uint32_t n = 0; n < 32u; ++n) {
        CxWorld* owned = (CxWorld*)tx_persistent_alloc(sizeof(CxWorld));
        assert(owned);
        memset(owned, 0, sizeof(*owned));
        owned->maximum = 2u * 1024u * 1024u;
        owned->bytes = sizeof(CxWorld) + 32u;
        install_viewport(owned);
        owned->viewport_pinned = owned->viewport_probe = owned->viewport_hit = 1;
        owned->result = cx_alloc(owned, 64u);
        assert(owned->result);
        destroy(owned);
        assert(live_count == live_before);
    }
}

static void timer_workspace_pressure(void) {
    Run r;
    run_setup(&r);
    CxDevice devices[2] = {0};
    uint32_t mechs[999] = {0};
    TxTile column[20] = {0};
    r.w.width = r.w.height = 20;
    r.w.devices = devices; r.w.device_count = 2;
    r.w.mechs = mechs; r.w.mech_capacity = 999;
    for (uint32_t i = 0; i < 2; ++i) {
        devices[i].x = 5u + i; devices[i].y = 10u;
        devices[i].tile.active = 1; devices[i].tile.type = 144;
        devices[i].nets[0] = 1;
    }
    cx_timer_order_prepare(&r.w);
    assert(r.w.timer_order);
    r.w.column = column;
    for (uint32_t x = 5; x < 8; ++x) {
        r.w.x = x;
        cx_timer_order_cell(&r.w, 10, 0, 1, 1, 1, 0);
    }
    r.w.column = NULL;
    cx_timer_order_finish(&r.w);
    CxTimerOrder* timer = r.w.timer_order;
    begin_pulse(&r);
    assert(terra_vm_step(r.w.vm, 3) == TERRA_VM_MORE);
    install_viewport(&r.w);
    uint32_t maximum = r.w.bytes + r.w.vm->allocated + 32u;
    r.w.maximum = maximum;
    assert(terra_vm_set_owner_budget(r.w.vm, cx_vm_available(&r.w)) == 0);
    r.w.operation_active = 1;
    r.w.seed_x = 7; r.w.seed_y = 10; r.w.seed_width = r.w.seed_height = 1;
    cx_timer_order_begin(&r.w);
    for (uint32_t i = 0; i < 2; ++i) cx_timer_order_hit(&r.w, devices + i, 0, 1);
    int status;
    uint32_t steps = 0;
    do {
        status = cx_timer_order_step(&r.w);
        assert(status >= 0 && ++steps < 1000u);
        assert(r.w.timer_order == timer && r.w.vm->active && r.w.maximum == maximum);
        check_budget(&r.w);
    } while (status);
    assert(!r.w.viewport_cells && !r.w.error && timer->queue && timer->seen);
    assert(r.w.mech_count == 2 && r.w.mechs[0] == 1 && r.w.mechs[1] == 0);
    r.w.operation_active = 0;
    run_cleanup(&r);
}

int main(void) {
    for (uint32_t growth = CANDIDATE_FIRST; growth <= DONE_GROW; ++growth)
        for (int oom = 0; oom < 2; ++oom) active_growth((enum Growth)growth, oom);
    pinned_and_refusal();
    for (int optional = 0; optional < 2; ++optional)
        for (int oom = 0; oom < 2; ++oom) owner_pressure(optional, oom);
    terminal_failures();
    production_registration();
    binding_and_override_pressure();
    cap_and_result_priority();
    replacement_and_result_ownership();
    streamed_probe_preserves_scan_state();
    optional_oom_and_destroy();
    timer_workspace_pressure();
    assert(!live_count && !failures_left);
    printf("PASS: viewport ownership, 4096-cell cap, %zu-byte entries, %zu-byte slab payload, "
           "%zu-byte charged slab overhead, budget/OOM reclaim before active VM candidate/queue/done growth, "
           "equal per-step counters/parity without replay, owner/result/timer pressure, "
           "pinned protection, optional refusal, terminal failures, production hook registration, "
           "128 slab-reusing pans/restarts, streamed probe state isolation, pending-result ownership, "
           "and 32 leak-free destroy cycles\n",
           sizeof(CxViewportCell), (size_t)CX_VIEWPORT_CELLS * sizeof(CxViewportCell),
           sizeof(CxAllocation) + 32u);
    return 0;
}
