/* Synthetic-only tcmalloc contract. No product, threads, sleeps or signal cuts.
 * 15 malloc-family operations; original logical oracle is unchanged. Eight
 * Heaptrack marker malloc/free calls are replaced by five synchronous Dumps.
 * Offline build stubs only the profiler API, and cannot satisfy the CI gate.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef GPERFTOOLS_OFFLINE
#include <dlfcn.h>
#include <gperftools/heap-profiler.h>
#else
static int offline_running = 1;
static int IsHeapProfilerRunning(void) { return offline_running; }
static void HeapProfilerDump(const char *reason) { (void)reason; }
static void HeapProfilerStop(void) { offline_running = 0; }
#endif
#define EXPORTED __attribute__((noinline,used,visibility("default")))
#define COUNT 6
struct Owner { void *pointer; uintptr_t bits; size_t bytes; };
struct Op { const char *name; const char *kind; unsigned owner; uintptr_t old, result; size_t bytes; int success, freed, error; };
struct Cut { unsigned ordinal, live_blocks; size_t live_bytes; size_t sizes[COUNT]; };
static struct Owner owners[COUNT];
static struct Op operations[32];
static struct Cut cuts[5];
static const char *cut_names[5] = {"q0.begin", "q0.end", "q7.begin", "q7.end", "cleanup"};
/* Independently authored sizes, copied logically, not inferred from profiles. */
static const size_t expected[5][COUNT] = {
    {101,219,0,0,0,0}, {409,0,307,0,0,0}, {409,0,0,0,601,0},
    {0,0,0,0,809,749}, {0,0,0,0,0,0}
};
static unsigned operation_count, failures, dump_count;
static int zero_freed, failure_enomem, initial_running, stopped;
static volatile size_t impossible_size = SIZE_MAX;
static const char *malloc_provider = "offline-no-profiler";
static const char *dump_provider = "offline-no-profiler";
static __attribute__((noinline)) uintptr_t bits(const void *p) { return (uintptr_t)p; }
static void fill(void *p, size_t n, unsigned owner) {
    volatile unsigned char *q=p;
    for (size_t i=0; i<n; ++i) q[i]=(unsigned char)(0xa0u+owner);
}
static int check(const void *p, size_t n, unsigned char value) {
    const volatile unsigned char *q=p;
    for (size_t i=0; i<n; ++i) if (q[i]!=value) return 0;
    return 1;
}
static void record(const char *name, const char *kind, unsigned owner,
                   uintptr_t old, void *result, size_t n, int success, int freed, int error) {
    if (operation_count>=32) { failures|=1; return; }
    operations[operation_count++]=(struct Op){name,kind,owner,old,bits(result),n,success,freed,error};
}
static void accept(unsigned owner, void *p, size_t n) {
    owners[owner]=(struct Owner){p,bits(p),p?n:0};
    if (!p) failures|=2;
    else fill(p,n,owner);
}
#define MALLOC_SITE(name,owner,n) \
EXPORTED void name(void) { \
    errno=0; void *p=malloc(n); int e=errno; \
    record(#name,"malloc",owner,0,p,n,p!=NULL,0,e); accept(owner,p,n); \
}
#define CALLOC_SITE(name,owner,count,size) \
EXPORTED void name(void) { \
    errno=0; void *p=calloc(count,size); int e=errno; \
    record(#name,"calloc",owner,0,p,(count)*(size),p!=NULL,0,e); \
    if (p && !check(p,(count)*(size),0)) failures|=4; \
    accept(owner,p,(count)*(size)); \
}
#define GROW_SITE(name,owner,n) \
EXPORTED void name(void) { \
    uintptr_t old=owners[owner].bits; size_t previous=owners[owner].bytes; \
    errno=0; void *p=realloc(owners[owner].pointer,n); int e=errno; \
    record(#name,"realloc",owner,old,p,n,p!=NULL,p!=NULL,e); \
    if (!p) { failures|=8; return; } \
    if (!check(p,previous,(unsigned char)(0xa0u+owner))) failures|=16; \
    accept(owner,p,n); \
}
MALLOC_SITE(abc_alloc_baseline,0,101)
CALLOC_SITE(abc_alloc_pre_calloc,1,3,73)
MALLOC_SITE(abc_alloc_q0_transient,2,307)
GROW_SITE(abc_alloc_baseline_grow,0,409)
MALLOC_SITE(abc_alloc_zero503,3,503)
MALLOC_SITE(abc_alloc_gap,4,601)
CALLOC_SITE(abc_alloc_q7_calloc,5,7,107)
GROW_SITE(abc_alloc_gap_grow,4,809)
EXPORTED void abc_fixture_free(unsigned owner, const char *name) {
    uintptr_t old=owners[owner].bits;
    free(owners[owner].pointer);
    record(name,"free",owner,old,NULL,0,1,old!=0,0);
    owners[owner]=(struct Owner){NULL,0,0};
}
EXPORTED void abc_fixture_realloc_failure(void) {
    uintptr_t old=owners[0].bits;
    size_t n=impossible_size;
    errno=0; void *p=realloc(owners[0].pointer,n); int e=errno;
    record("realloc_failure_size_max","realloc",0,old,p,n,p!=NULL,p!=NULL,e);
    failure_enomem=p==NULL && e==ENOMEM;
    if (!failure_enomem) { failures|=32; if (p) owners[0]=(struct Owner){p,bits(p),n}; }
    else if (!check(owners[0].pointer,owners[0].bytes,0xa0u)) failures|=64;
}
EXPORTED void abc_fixture_realloc_zero(void) {
    uintptr_t old=owners[3].bits;
    errno=0; void *p=realloc(owners[3].pointer,0); int e=errno;
    /* Fixed official tcmalloc source frees non-NULL p and returns NULL here.
     * Never dereference/free the invalid former pointer. Runtime provider and
     * per-site cumulative/live profile accounting corroborate this premise. */
    zero_freed=old!=0 && p==NULL;
    record("realloc_zero_frees_source","realloc",3,old,p,0,zero_freed,zero_freed,e);
    owners[3]=(struct Owner){p,bits(p),0};
    if (!zero_freed) { failures|=128; if (p) abc_fixture_free(3,"unexpected_zero_cleanup"); }
}
static void snapshot(unsigned c) {
    struct Cut *cut=&cuts[c];
    cut->ordinal=operation_count;
    for (unsigned i=0;i<COUNT;++i) {
        cut->sizes[i]=owners[i].bytes;
        if (owners[i].pointer) { ++cut->live_blocks; cut->live_bytes+=owners[i].bytes; }
        if (owners[i].bytes!=expected[c][i] || (owners[i].pointer!=NULL)!=(expected[c][i]!=0)) failures|=256;
    }
    HeapProfilerDump(cut_names[c]);
    ++dump_count;
}
EXPORTED void q0_begin(void) { snapshot(0); }
EXPORTED void q0_end(void) { snapshot(1); }
EXPORTED void q7_begin(void) { snapshot(2); }
EXPORTED void q7_end(void) { snapshot(3); }
EXPORTED void final_cleanup(void) { snapshot(4); }
static void run(void) {
    abc_alloc_baseline();
    abc_alloc_pre_calloc();
    q0_begin();
    abc_alloc_q0_transient();
    abc_alloc_baseline_grow();
    abc_fixture_free(1,"free_pre_calloc_in_q0");
    abc_alloc_zero503();
    abc_fixture_realloc_failure();
    abc_fixture_realloc_zero();
    q0_end();
    abc_fixture_free(2,"free_q0_transient_in_gap");
    abc_alloc_gap();
    q7_begin();
    abc_fixture_free(0,"free_baseline_in_q7");
    abc_alloc_q7_calloc();
    abc_alloc_gap_grow();
    q7_end();
    abc_fixture_free(4,"free_gap_after_q7");
    abc_fixture_free(5,"free_q7_calloc_after_q7");
    final_cleanup();
    HeapProfilerStop();
    stopped=!IsHeapProfilerRunning();
    if (!stopped || operation_count!=15 || dump_count!=5) failures|=512;
}
static void emit(void) {
    printf("{\"type\":\"metadata\",\"schema\":\"abc.gperftools-contract.v1\",\"hostPid\":%ld,\"pointerWidthBits\":%zu,\"enomem\":%d,\"mallocProvider\":\"%s\",\"dumpProvider\":\"%s\",\"initialRunning\":%d,\"offline\":%s}\n",
           (long)getpid(),sizeof(void*)*8,ENOMEM,malloc_provider,dump_provider,initial_running,
#ifdef GPERFTOOLS_OFFLINE
           "true"
#else
           "false"
#endif
    );
    for (unsigned i=0;i<operation_count;++i) {
        const struct Op *op=&operations[i];
        printf("{\"type\":\"operation\",\"ordinal\":%u,\"name\":\"%s\",\"kind\":\"%s\",\"owner\":%u,\"oldPointer\":\"0x%" PRIxPTR "\",\"resultPointer\":\"0x%" PRIxPTR "\",\"requestedBytes\":%zu,\"success\":%d,\"formerAllocationFreed\":%d,\"errno\":%d}\n",i,op->name,op->kind,op->owner,op->old,op->result,op->bytes,op->success,op->freed,op->error);
    }
    for (unsigned c=0;c<5;++c) {
        printf("{\"type\":\"cut\",\"id\":\"%s\",\"dumpOrdinal\":%u,\"operationOrdinal\":%u,\"liveBytes\":%zu,\"liveBlocks\":%u,\"ownerSizes\":[",cut_names[c],c+1,cuts[c].ordinal,cuts[c].live_bytes,cuts[c].live_blocks);
        for (unsigned i=0;i<COUNT;++i) printf("%s%zu",i?",":"",cuts[c].sizes[i]);
        puts("]}");
    }
    printf("{\"type\":\"summary\",\"authoredOperations\":%u,\"dumpCount\":%u,\"reallocZeroFreed\":%d,\"reallocFailureEnomem\":%d,\"stopped\":%d,\"semanticFailureBits\":%u}\n",operation_count,dump_count,zero_freed,failure_enomem,stopped,failures);
}
int main(void) {
    initial_running=IsHeapProfilerRunning();
    if (!initial_running) return 3; /* Never start the profiler at a quiet cut. */
#ifndef GPERFTOOLS_OFFLINE
    Dl_info allocation_info, profiler_info;
    void *allocation=dlsym(RTLD_DEFAULT,"malloc");
    void *profiler=dlsym(RTLD_DEFAULT,"HeapProfilerDump");
    if (!allocation || !profiler || !dladdr(allocation,&allocation_info) ||
        !dladdr(profiler,&profiler_info) || !allocation_info.dli_fname || !profiler_info.dli_fname) return 4;
    malloc_provider=allocation_info.dli_fname;
    dump_provider=profiler_info.dli_fname;
    /* The launcher passes a verified absolute library path in LD_PRELOAD.
     * Require both API providers to match it before any authored allocation. */
    const char *expected_provider=getenv("LD_PRELOAD");
    if (!expected_provider || strcmp(malloc_provider,expected_provider) || strcmp(dump_provider,expected_provider)) return 5;
#endif
    run();
    emit(); /* All fixture allocations freed and profiler stopped before stdio. */
    if (ferror(stdout) || fflush(stdout)==EOF) return 2;
    return failures?1:0;
}
