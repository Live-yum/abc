/* Offline state-machine oracle. It does not implement or invoke a profiler. */
#define _POSIX_C_SOURCE 200809L
#include "quiet_dump_bridge.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct abc_quiet_context context;
static struct {
    const char *mode;
    uint64_t now;
    unsigned provider_calls,map_calls,dumps,stops,publishes,acks;
    int running;
    char events[4096];size_t used;
} stub;
static void event(const char *name) {
    int n=snprintf(stub.events+stub.used,sizeof stub.events-stub.used,"%s%s",stub.used?",":"",name);
    if(n<0 || (size_t)n>=sizeof stub.events-stub.used) abort();
    stub.used+=(size_t)n;
}
static int mode(const char *name) {return !strcmp(name,stub.mode);}
static uint64_t tick(void *unused) {(void)unused;stub.now+=100;return mode("zero-clock")?0:stub.now;}
static int provider(void *unused) {
    (void)unused;++stub.provider_calls;event("provider");
    return !mode("wrong-provider") && !(mode("provider-changed") && stub.provider_calls>=3);
}
static int running(void *unused) {(void)unused;event("running");return stub.running;}
static void dump(void *unused,const char *reason) {
    (void)unused;++stub.dumps;event(reason);
    if(mode("slow-dump")) stub.now+=ABC_HOOK_NS;
}
static void stop(void *unused) {
    (void)unused;++stub.stops;event("stop");
    if(!mode("stop-failure") && !mode("ack-and-stop-failure")) stub.running=0;
}
static int maps(void *unused,char *buffer,size_t cap,size_t *length) {
    (void)unused;++stub.map_calls;event("maps");
    const char text[]="00001000-00002000 r-xp 00000000 08:01 17 /fixture.so\n";
    if(mode("maps-overflow")) {*length=cap+1;return -1;}
    if(mode("maps-read-error")) {*length=9;return -1;}
    memcpy(buffer,text,sizeof text-1);*length=sizeof text-1;return 0;
}
static int publish(void *unused,unsigned slot,const struct abc_quiet_cut *cut,const char *before,const char *after) {
    (void)unused;++stub.publishes;event("publish");
    if(slot!=(cut->cycle==7?1u:0u) || cut->maps_before_size!=cut->maps_after_size ||
       memcmp(before,after,cut->maps_before_size)) abort();
    return mode("publish-failure")?-1:0;
}
static int ack(void *unused,unsigned slot,int cycle,uint64_t deadline) {
    (void)unused;(void)slot;(void)cycle;++stub.acks;event("ack");
    if(mode("late-ack")) stub.now=deadline;
    return mode("ack-failure") || mode("ack-and-stop-failure")?-1:0;
}
static int cut(int cycle,uint64_t dart_us) {event(cycle==7?"gauge7":"gauge0");return abc_quiet_core_after_gauge(&context,cycle,dart_us);}
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    stub.mode=argv[1];stub.now=100000;stub.running=!mode("not-running");
    const struct abc_quiet_ops ops={NULL,tick,provider,running,dump,stop,maps,publish,ack};
    int init=abc_quiet_core_init(&context,&ops,1),a=-1,b=-1,c=-1;
    if(!init) {
        if(mode("failure-finally")) {event("workload-failure");}
        else if(mode("wrong-order")) a=cut(7,1234);
        else if(mode("wrong-cycle")) a=cut(3,1234);
        else {
            a=cut(0,1234);
            if(!a) {
                if(mode("repeat")) b=cut(0,5678);
                else if(mode("stop-before-q7")) {abc_quiet_core_stop(&context);b=cut(7,5678);}
                else b=cut(7,5678);
                if(!b && mode("third")) c=cut(7,9999);
            }
        }
    }
    event("finally");
    int stopped=abc_quiet_core_stop(&context),again=abc_quiet_core_stop(&context);
    const struct abc_quiet_metadata *m=&context.meta;
    printf("{\"offline\":true,\"realProfilerInvoked\":false,\"init\":%d,\"a\":%d,\"b\":%d,\"c\":%d,\"stop\":%d,\"stopAgain\":%d,\"failure\":%d,\"cleanupFailure\":%d,\"stopCalls\":%u,\"stopVerified\":%d,\"dumps\":%u,\"slots\":%u,\"maps\":%u,\"publishes\":%u,\"acks\":%u,\"observerBytes\":%" PRIu64 ",\"events\":\"%s\",\"cuts\":[",init,a,b,c,stopped,again,m->failure,m->cleanup_failure,m->stop_calls,m->stop_verified,m->dump_count,m->slots_used,stub.map_calls,stub.publishes,stub.acks,m->observer_preallocated_bytes,stub.events);
    for(unsigned i=0;i<2;i++) {
        const struct abc_quiet_cut *q=&m->cuts[i];
        printf("%s{\"cycle\":%d,\"accepted\":%d,\"gaugeDartUs\":%" PRIu64 ",\"entryNs\":%" PRIu64 ",\"dumpStartNs\":%" PRIu64 ",\"dumpEndNs\":%" PRIu64 ",\"ackEndNs\":%" PRIu64 ",\"exitNs\":%" PRIu64 ",\"beforeSize\":%zu,\"afterSize\":%zu}",i?",":"",q->cycle,q->accepted,q->gauge_dart_us,q->enter_ns,q->dump_start_ns,q->dump_end_ns,q->ack_end_ns,q->exit_ns,q->maps_before_size,q->maps_after_size);
    }
    puts("]}");return 0;
}
