/*
 * A bounded, synthetic allocator contract for a single Heaptrack capture.
 *
 * Normal path: 23 authored allocator calls, including eight marker calls.
 * The four cuts are immediately BEFORE their marker mallocs.  Marker blocks
 * never count as fixture ownership.  No output/stdio occurs until all fixture
 * and marker allocations have been released.  The JSONL manifest is the
 * semantic oracle, not a claim that a profiler has captured these events.
 *
 * Build with:
 * cc -std=c11 -O2 -g -Wall -Wextra -Werror -fno-builtin-malloc \
 *    -fno-builtin-free -fno-optimize-sibling-calls -rdynamic \
 *    native_contract.c -o native_contract
 *
 * Exit 0: semantic contract and JSON emission passed.
 * Exit 1: allocation/runtime semantics did not satisfy the contract.
 * Exit 2: JSON emission failed (including a failed final flush).
 * Linux/glibc realloc(p, 0) returning NULL is an intentional requirement.
 */

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define MAX_OPERATIONS 32u
#define CUT_COUNT 4u
#define OWNER_COUNT 6u
#define NOINLINE __attribute__((noinline))
#if defined(__GNUC__) && !defined(__clang__)
#define NOCLONE __attribute__((noclone))
#else
#define NOCLONE
#endif
#define EXPORTED_MARKER NOCLONE __attribute__((noinline, used, visibility("default")))

enum OwnerId { BASELINE, PRE_CALLOC, Q0_TEMP, ZERO_PROBE, GAP, Q7_CALLOC };
enum Failure {
    FAIL_ALLOCATION = 1u << 0,
    FAIL_CALLOC_CONTENT = 1u << 1,
    FAIL_REALLOC_CONTENT = 1u << 2,
    FAIL_REALLOC_FAILURE = 1u << 3,
    FAIL_REALLOC_ZERO = 1u << 4,
    FAIL_MARKER = 1u << 5,
    FAIL_CUT = 1u << 6,
    FAIL_CAPACITY = 1u << 7,
    FAIL_FINAL_LIVE = 1u << 8
};

struct Owner {
    const char *name;
    void *pointer;
    uintptr_t bits;
    size_t bytes;
    int live;
};

struct Operation {
    const char *name;
    const char *kind;
    const char *marker_symbol;
    int owner;
    uintptr_t pointer;
    uintptr_t old_pointer;
    uintptr_t result_pointer;
    size_t requested_bytes;
    size_t count;
    size_t element_bytes;
    int success;
    int error_number;
    int former_freed;
};

struct CutOwner {
    uintptr_t pointer;
    size_t bytes;
    int live;
};

struct Cut {
    const char *id;
    const char *symbol;
    unsigned int operation_ordinal;
    uintptr_t pointer;
    size_t requested_bytes;
    struct CutOwner owners[OWNER_COUNT];
    size_t live_bytes;
    unsigned int live_blocks;
};

static struct Owner owners[OWNER_COUNT] = {
    { "baseline_malloc", NULL, 0, 0, 0 },
    { "pre_calloc", NULL, 0, 0, 0 },
    { "q0_transient", NULL, 0, 0, 0 },
    { "realloc_zero_source", NULL, 0, 0, 0 },
    { "gap_malloc", NULL, 0, 0, 0 },
    { "q7_calloc", NULL, 0, 0, 0 }
};
static struct Operation operations[MAX_OPERATIONS];
static struct Cut cuts[CUT_COUNT] = {
    { .id = "q0.begin", .symbol = "q0_begin", .requested_bytes = 13 },
    { .id = "q0.end", .symbol = "q0_end", .requested_bytes = 17 },
    { .id = "q7.begin", .symbol = "q7_begin", .requested_bytes = 19 },
    { .id = "q7.end", .symbol = "q7_end", .requested_bytes = 23 }
};
/* An independently authored semantic schedule; zero means no live owner. */
static const size_t expected_sizes[CUT_COUNT][OWNER_COUNT] = {
    { 101, 219,   0, 0,   0,   0 },
    { 409,   0, 307, 0,   0,   0 },
    { 409,   0,   0, 0, 601,   0 },
    {   0,   0,   0, 0, 809, 749 }
};
static unsigned int operation_count;
static unsigned int marker_count;
static unsigned int failures;
static volatile uintptr_t marker_sink;
static volatile size_t impossible_realloc_size = SIZE_MAX;
static int realloc_zero_freed;
static int realloc_zero_returned_null;
static int realloc_failure_enomem;
static size_t final_live_bytes;
static unsigned int final_live_blocks;

/* Capture identities while valid, without later evaluating an invalid pointer. */
static NOINLINE uintptr_t pointer_identity(const void *pointer)
{
    return (uintptr_t)pointer;
}

static void record_operation(const char *name, const char *kind, int owner,
                             uintptr_t pointer, uintptr_t old_pointer,
                             uintptr_t result_pointer, size_t requested_bytes,
                             int success, int error_number, int former_freed,
                             const char *marker_symbol,
                             size_t count, size_t element_bytes)
{
    if (operation_count >= MAX_OPERATIONS) {
        failures |= FAIL_CAPACITY;
        return;
    }
    operations[operation_count++] = (struct Operation) {
        .name = name, .kind = kind, .marker_symbol = marker_symbol,
        .owner = owner, .pointer = pointer, .old_pointer = old_pointer,
        .result_pointer = result_pointer, .requested_bytes = requested_bytes,
        .count = count, .element_bytes = element_bytes, .success = success,
        .error_number = error_number, .former_freed = former_freed
    };
}

static void set_owner(enum OwnerId owner, void *pointer, size_t bytes)
{
    owners[owner].pointer = pointer;
    owners[owner].bits = pointer_identity(pointer);
    owners[owner].bytes = pointer != NULL ? bytes : 0;
    owners[owner].live = pointer != NULL;
}

static void fill_bytes(void *pointer, size_t bytes, unsigned char value)
{
    volatile unsigned char *target = pointer;
    for (size_t i = 0; i < bytes; ++i) {
        target[i] = value;
    }
}

static int check_bytes(const void *pointer, size_t bytes, unsigned char value)
{
    const volatile unsigned char *source = pointer;
    for (size_t i = 0; i < bytes; ++i) {
        if (source[i] != value) {
            return 0;
        }
    }
    return 1;
}

EXPORTED_MARKER void abc_fixture_malloc(enum OwnerId owner, size_t bytes)
{
    errno = 0;
    void *pointer = malloc(bytes);
    int error_number = errno;
    uintptr_t bits = pointer_identity(pointer);
    record_operation(owners[owner].name, "malloc", owner, bits, 0, bits,
                     bytes, pointer != NULL, error_number, 0, NULL, 1, bytes);
    set_owner(owner, pointer, bytes);
    if (pointer == NULL) {
        failures |= FAIL_ALLOCATION;
    } else {
        fill_bytes(pointer, bytes, (unsigned char)(0xa0u + owner));
    }
}

EXPORTED_MARKER void abc_fixture_calloc(enum OwnerId owner,
                                   size_t count, size_t element_bytes)
{
    size_t bytes = count * element_bytes;
    errno = 0;
    void *pointer = calloc(count, element_bytes);
    int error_number = errno;
    uintptr_t bits = pointer_identity(pointer);
    record_operation(owners[owner].name, "calloc", owner, bits, 0, bits,
                     bytes, pointer != NULL, error_number, 0, NULL,
                     count, element_bytes);
    set_owner(owner, pointer, bytes);
    if (pointer == NULL) {
        failures |= FAIL_ALLOCATION;
    } else {
        if (!check_bytes(pointer, bytes, 0)) {
            failures |= FAIL_CALLOC_CONTENT;
        }
        fill_bytes(pointer, bytes, (unsigned char)(0xa0u + owner));
    }
}

EXPORTED_MARKER void abc_fixture_free(enum OwnerId owner, const char *name)
{
    uintptr_t old_bits = owners[owner].bits;
    int was_live = owners[owner].live;
    free(owners[owner].pointer);
    record_operation(name, "free", owner, old_bits, old_bits, 0,
                     0, 1, 0, was_live, NULL, 0, 0);
    set_owner(owner, NULL, 0);
}

EXPORTED_MARKER void abc_fixture_grow(enum OwnerId owner, const char *name,
                                 size_t bytes)
{
    uintptr_t old_bits = owners[owner].bits;
    size_t old_bytes = owners[owner].bytes;
    int was_live = owners[owner].live;
    errno = 0;
    void *result = realloc(owners[owner].pointer, bytes);
    int error_number = errno;
    uintptr_t result_bits = pointer_identity(result);
    record_operation(name, "realloc", owner, result_bits, old_bits,
                     result_bits, bytes, result != NULL, error_number,
                     was_live && result != NULL, NULL, 1, bytes);
    if (result == NULL) {
        failures |= FAIL_ALLOCATION;
        return; /* The prior owner remains live on failure. */
    }
    set_owner(owner, result, bytes);
    if (!was_live || !check_bytes(result, old_bytes,
                                 (unsigned char)(0xa0u + owner))) {
        failures |= FAIL_REALLOC_CONTENT;
    }
    fill_bytes(result, bytes, (unsigned char)(0xa0u + owner));
}

EXPORTED_MARKER void abc_fixture_realloc_failure(void)
{
    uintptr_t old_bits = owners[BASELINE].bits;
    size_t requested_bytes = impossible_realloc_size;
    errno = 0;
    void *result = realloc(owners[BASELINE].pointer, requested_bytes);
    int error_number = errno;
    uintptr_t result_bits = pointer_identity(result);
    record_operation("realloc_failure_size_max", "realloc", BASELINE,
                     result_bits, old_bits, result_bits, requested_bytes,
                     result != NULL, error_number, result != NULL,
                     NULL, 1, requested_bytes);
    realloc_failure_enomem = result == NULL && error_number == ENOMEM;
    if (!realloc_failure_enomem || !owners[BASELINE].live) {
        failures |= FAIL_REALLOC_FAILURE;
    }
    if (result != NULL) {
        /* Defensive cleanup only: SIZE_MAX cannot be supplied on this target. */
        set_owner(BASELINE, result, requested_bytes);
    } else if (owners[BASELINE].live &&
               !check_bytes(owners[BASELINE].pointer, owners[BASELINE].bytes,
                            0xa0u + BASELINE)) {
        failures |= FAIL_REALLOC_FAILURE;
    }
}

EXPORTED_MARKER void abc_fixture_realloc_zero(void)
{
    uintptr_t old_bits = owners[ZERO_PROBE].bits;
    int was_live = owners[ZERO_PROBE].live;
    errno = 0;
    void *result = realloc(owners[ZERO_PROBE].pointer, 0);
    int error_number = errno;
    uintptr_t result_bits = pointer_identity(result);
    realloc_zero_returned_null = result == NULL;
#if defined(__linux__) && defined(__GLIBC__)
    realloc_zero_freed = was_live && result == NULL;
#else
    realloc_zero_freed = 0;
#endif
    record_operation("realloc_zero_frees_source", "realloc", ZERO_PROBE,
                     result_bits, old_bits, result_bits, 0,
                     realloc_zero_freed || result != NULL, error_number,
                     realloc_zero_freed, NULL, 1, 0);
    /* Do not dereference or free the old pointer after realloc(p, 0). */
    set_owner(ZERO_PROBE, result, 0);
    if (!realloc_zero_freed) {
        failures |= FAIL_REALLOC_ZERO;
    }
    if (result != NULL) {
        abc_fixture_free(ZERO_PROBE, "unexpected_realloc_zero_result_cleanup");
    }
}

static void snapshot_cut(unsigned int index)
{
    struct Cut *cut = &cuts[index];
    cut->operation_ordinal = operation_count;
    for (unsigned int owner = 0; owner < OWNER_COUNT; ++owner) {
        cut->owners[owner] = (struct CutOwner) {
            owners[owner].bits, owners[owner].bytes, owners[owner].live
        };
        if (owners[owner].live) {
            cut->live_bytes += owners[owner].bytes;
            ++cut->live_blocks;
        }
        if (owners[owner].live != (expected_sizes[index][owner] != 0) ||
            owners[owner].bytes != expected_sizes[index][owner]) {
            failures |= FAIL_CUT;
        }
    }
}

/*
 * Each exported marker contains its own real allocator calls.  The volatile
 * access prevents allocation elimination; the post-free volatile write and
 * build flag prevent a sibling/tail call from dropping the marker frame.
 */
#define DEFINE_MARKER(symbol_name, cut_index, allocation_bytes)                 \
    EXPORTED_MARKER void symbol_name(void)                                     \
    {                                                                         \
        snapshot_cut(cut_index);                                              \
        errno = 0;                                                            \
        void *pointer = malloc(allocation_bytes);                             \
        int error_number = errno;                                             \
        uintptr_t bits = pointer_identity(pointer);                           \
        if (pointer != NULL) {                                                \
            *(volatile unsigned char *)pointer = (unsigned char)(cut_index);  \
            marker_sink ^= *(volatile unsigned char *)pointer;                \
        } else {                                                              \
            failures |= FAIL_MARKER;                                          \
        }                                                                     \
        record_operation(#symbol_name, "malloc", -1, bits, 0, bits,          \
                         allocation_bytes, pointer != NULL, error_number,     \
                         0, #symbol_name, 1, allocation_bytes);                \
        free(pointer);                                                        \
        record_operation(#symbol_name "_free", "free", -1, bits, bits, 0,    \
                         0, 1, 0, bits != 0, #symbol_name, 0, 0);              \
        cuts[cut_index].pointer = bits;                                        \
        ++marker_count;                                                       \
        marker_sink ^= bits;                                                  \
    }

DEFINE_MARKER(q0_begin, 0, 13)
DEFINE_MARKER(q0_end, 1, 17)
DEFINE_MARKER(q7_begin, 2, 19)
DEFINE_MARKER(q7_end, 3, 23)

static NOINLINE void run_contract(void)
{
    abc_fixture_malloc(BASELINE, 101);                 /* 0 */
    abc_fixture_calloc(PRE_CALLOC, 3, 73);              /* 1 */
    q0_begin();                                    /* 2, 3 */
    abc_fixture_malloc(Q0_TEMP, 307);                  /* 4 */
    abc_fixture_grow(BASELINE, "realloc_success_baseline", 409); /* 5 */
    abc_fixture_free(PRE_CALLOC, "free_pre_calloc_in_q0");       /* 6 */
    abc_fixture_malloc(ZERO_PROBE, 503);               /* 7 */
    abc_fixture_realloc_failure();                     /* 8 */
    abc_fixture_realloc_zero();                        /* 9 */
    q0_end();                                      /* 10, 11 */
    abc_fixture_free(Q0_TEMP, "free_q0_transient_in_gap");       /* 12 */
    abc_fixture_malloc(GAP, 601);                       /* 13 */
    q7_begin();                                    /* 14, 15 */
    abc_fixture_free(BASELINE, "free_baseline_in_q7");           /* 16 */
    abc_fixture_calloc(Q7_CALLOC, 7, 107);              /* 17 */
    abc_fixture_grow(GAP, "realloc_success_gap", 809);           /* 18 */
    q7_end();                                      /* 19, 20 */
    abc_fixture_free(GAP, "free_gap_after_q7");                 /* 21 */
    abc_fixture_free(Q7_CALLOC, "free_q7_calloc_after_q7");      /* 22 */
    if (operation_count != 23 || marker_count != CUT_COUNT) {
        failures |= FAIL_CAPACITY;
    }
    for (unsigned int owner = 0; owner < OWNER_COUNT; ++owner) {
        if (owners[owner].live) {
            failures |= FAIL_FINAL_LIVE;
            final_live_bytes += owners[owner].bytes;
            ++final_live_blocks;
        }
    }
}

static const char *json_boolean(int value)
{
    return value ? "true" : "false";
}

static void print_pointer(uintptr_t bits)
{
    if (bits == 0) {
        fputs("null", stdout);
    } else {
        printf("\"0x%" PRIxPTR "\"", bits);
    }
}

static void emit_manifest(void)
{
    printf("{\"type\":\"metadata\",\"schema\":\"abc.heaptrack-contract.v1\","
           "\"maxAuthoredOperations\":32,\"plannedAuthoredOperations\":23,"
           "\"cutSemantics\":\"immediately_before_marker_malloc\","
           "\"expectedLiveScope\":\"fixture_owned_excluding_markers\","
           "\"outputTiming\":\"after_all_authored_allocator_operations\","
           "\"hostPid\":%ld,\"pointerWidthBits\":%zu,\"sizeMax\":%zu,\"enomem\":%d,"
           "\"requiresLinuxGlibcReallocZero\":true}\n",
           (long)getpid(), sizeof(void *) * CHAR_BIT, (size_t)SIZE_MAX, ENOMEM);
    for (unsigned int i = 0; i < operation_count; ++i) {
        const struct Operation *op = &operations[i];
        printf("{\"type\":\"operation\",\"ordinal\":%u,\"name\":\"%s\","
               "\"kind\":\"%s\",\"pointer\":", i, op->name, op->kind);
        print_pointer(op->pointer);
        fputs(",\"oldPointer\":", stdout);
        print_pointer(op->old_pointer);
        fputs(",\"resultPointer\":", stdout);
        print_pointer(op->result_pointer);
        printf(",\"requestedBytes\":%zu,\"success\":%s,\"errno\":%d,"
               "\"formerAllocationFreed\":%s,\"count\":%zu,"
               "\"elementBytes\":%zu,\"markerOwned\":%s,\"markerSymbol\":",
               op->requested_bytes, json_boolean(op->success), op->error_number,
               json_boolean(op->former_freed), op->count, op->element_bytes,
               json_boolean(op->marker_symbol != NULL));
        if (op->marker_symbol == NULL) {
            fputs("null", stdout);
        } else {
            printf("\"%s\"", op->marker_symbol);
        }
        fputs(",\"ownerName\":", stdout);
        if (op->owner < 0) {
            fputs("null", stdout);
        } else {
            printf("\"%s\"", owners[op->owner].name);
        }
        /* Owner lifetime, not numeric address equality, defines this map. */
        fputs(",\"expectedLiveAtCuts\":{", stdout);
        for (unsigned int c = 0; c < CUT_COUNT; ++c) {
            const struct CutOwner *owner = op->owner < 0 ? NULL :
                                           &cuts[c].owners[op->owner];
            printf("%s\"%s\":{\"live\":%s,\"pointer\":", c ? "," : "",
                   cuts[c].id, json_boolean(owner != NULL && owner->live));
            print_pointer(owner != NULL && owner->live ? owner->pointer : 0);
            printf(",\"bytes\":%zu}", owner != NULL ? owner->bytes : 0);
        }
        fputs("}}\n", stdout);
    }
    for (unsigned int c = 0; c < CUT_COUNT; ++c) {
        const struct Cut *cut = &cuts[c];
        printf("{\"type\":\"marker\",\"id\":\"%s\",\"symbol\":\"%s\","
               "\"operationOrdinal\":%u,\"pointer\":", cut->id, cut->symbol,
               cut->operation_ordinal);
        print_pointer(cut->pointer);
        printf(",\"requestedBytes\":%zu,\"expectedLive\":[", cut->requested_bytes);
        unsigned int printed = 0;
        for (unsigned int owner = 0; owner < OWNER_COUNT; ++owner) {
            if (!cut->owners[owner].live) {
                continue;
            }
            printf("%s{\"pointer\":", printed++ ? "," : "");
            print_pointer(cut->owners[owner].pointer);
            printf(",\"bytes\":%zu,\"name\":\"%s\"}",
                   cut->owners[owner].bytes, owners[owner].name);
        }
        printf("],\"expectedLiveBytes\":%zu,\"expectedLiveBlocks\":%u}\n",
               cut->live_bytes, cut->live_blocks);
    }
    printf("{\"type\":\"summary\",\"completed\":%s,\"authoredOperations\":%u,"
           "\"markerCount\":%u,\"fixtureLiveBytes\":%zu,\"fixtureLiveBlocks\":%u,"
           "\"reallocZeroFreed\":%s,\"reallocZeroReturnedNull\":%s,"
           "\"reallocFailureEnomem\":%s,\"semanticFailureBits\":%u}\n",
           json_boolean(failures == 0), operation_count, marker_count,
           final_live_bytes, final_live_blocks,
           json_boolean(realloc_zero_freed),
           json_boolean(realloc_zero_returned_null),
           json_boolean(realloc_failure_enomem), failures);
}

int main(void)
{
    run_contract();
    emit_manifest();
    if (ferror(stdout) || fflush(stdout) == EOF) {
        return 2;
    }
    return failures == 0 ? 0 : 1;
}
