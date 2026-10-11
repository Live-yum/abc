#include "quiet_dump_bridge.h"
#include <string.h>

static int fail(struct abc_quiet_context *c,int error) {
    if(!c->meta.failure) c->meta.failure=error;
    if(c->meta.initialized) (void)abc_quiet_core_stop(c);
    return error;
}
int abc_quiet_core_init(struct abc_quiet_context *c,const struct abc_quiet_ops *ops,unsigned offline) {
    if(!c || !ops || c->meta.abi || !ops->clock_ns || !ops->provider_matches || !ops->running ||
       !ops->dump || !ops->stop || !ops->map_read || !ops->publish || !ops->wait_ack) return ABC_QUIET_BAD_INIT;
    c->ops=*ops;
    c->meta.abi=ABC_QUIET_ABI;c->meta.offline=offline;
    c->meta.observer_preallocated_bytes=sizeof *c;
    c->meta.observer_maps_bytes=2u*ABC_MAP_CAP;
    c->meta.cuts[0].cycle=0;c->meta.cuts[1].cycle=7;
    if(!ops->provider_matches(ops->user)) return fail(c,ABC_QUIET_PROVIDER);
    c->meta.initialized=1;
    if(!ops->running(ops->user)) return fail(c,ABC_QUIET_NOT_RUNNING);
    return ABC_QUIET_OK;
}
int abc_quiet_core_stop(struct abc_quiet_context *c) {
    if(!c || !c->meta.initialized) return ABC_QUIET_BAD_INIT;
    if(c->meta.stop_requested) return c->meta.stop_verified?ABC_QUIET_OK:ABC_QUIET_STOP_FAILED;
    c->meta.stop_requested=1;
    c->meta.stop_start_ns=c->ops.clock_ns(c->ops.user);
    ++c->meta.stop_calls;
    c->ops.stop(c->ops.user);
    c->meta.stop_verified=!c->ops.running(c->ops.user);
    c->meta.stop_end_ns=c->ops.clock_ns(c->ops.user);
    if(!c->meta.stop_verified) {
        c->meta.cleanup_failure=ABC_QUIET_STOP_FAILED;
        if(!c->meta.failure) c->meta.failure=ABC_QUIET_STOP_FAILED;
        return ABC_QUIET_STOP_FAILED;
    }
    return ABC_QUIET_OK;
}
static int timed_out(struct abc_quiet_context *c,uint64_t start) {
    uint64_t now=c->ops.clock_ns(c->ops.user);
    if(!start || now<start) return ABC_QUIET_CLOCK;
    return now-start>=ABC_HOOK_NS?ABC_QUIET_TIMEOUT:ABC_QUIET_OK;
}
int abc_quiet_core_after_gauge(struct abc_quiet_context *c,int cycle,uint64_t gauge_dart_us) {
    if(!c || !c->meta.initialized) return ABC_QUIET_BAD_INIT;
    if(c->meta.failure) return c->meta.failure;
    if(c->meta.stop_requested) return fail(c,ABC_QUIET_STOPPED);
    unsigned slot=c->meta.slots_used;
    if(slot>=2 || cycle!=(slot==0?0:7)) return fail(c,ABC_QUIET_CUT_ORDER);
    struct abc_quiet_cut *cut=&c->meta.cuts[slot];
    cut->gauge_dart_us=gauge_dart_us;cut->enter_ns=c->ops.clock_ns(c->ops.user);
    ++c->meta.slots_used; /* An attempted cut is consumed, even if IO fails. */
    int error=0;
    if(!cut->enter_ns) {error=ABC_QUIET_CLOCK;goto failed;}
    if(!c->ops.provider_matches(c->ops.user)) {error=ABC_QUIET_PROVIDER;goto failed;}
    if(!c->ops.running(c->ops.user)) {error=ABC_QUIET_NOT_RUNNING;goto failed;}
    if(c->ops.map_read(c->ops.user,c->maps_before,ABC_MAP_CAP,&cut->maps_before_size) ||
       !cut->maps_before_size || cut->maps_before_size>ABC_MAP_CAP) {error=ABC_QUIET_MAPS;goto failed;}
    if((error=timed_out(c,cut->enter_ns))) goto failed;
    cut->dump_start_ns=c->ops.clock_ns(c->ops.user);
    ++c->meta.dump_count;
    c->ops.dump(c->ops.user,slot==0?"q0.released-quiet-end":"q7.released-quiet-end");
    cut->dump_end_ns=c->ops.clock_ns(c->ops.user);
    if(cut->dump_end_ns<cut->dump_start_ns) {error=ABC_QUIET_CLOCK;goto failed;}
    if((error=timed_out(c,cut->enter_ns))) goto failed;
    if(c->ops.map_read(c->ops.user,c->maps_after,ABC_MAP_CAP,&cut->maps_after_size) ||
       !cut->maps_after_size || cut->maps_after_size>ABC_MAP_CAP) {error=ABC_QUIET_MAPS;goto failed;}
    if(!c->ops.provider_matches(c->ops.user)) {error=ABC_QUIET_PROVIDER;goto failed;}
    if(c->ops.publish(c->ops.user,slot,cut,c->maps_before,c->maps_after)) {error=ABC_QUIET_IO;goto failed;}
    if((error=timed_out(c,cut->enter_ns))) goto failed;
    uint64_t now=c->ops.clock_ns(c->ops.user);
    uint64_t deadline=now+ABC_ACK_NS;
    if(deadline<now) {error=ABC_QUIET_CLOCK;goto failed;}
    if(deadline>cut->enter_ns+ABC_HOOK_NS) deadline=cut->enter_ns+ABC_HOOK_NS;
    if(c->ops.wait_ack(c->ops.user,slot,cycle,deadline)) {error=ABC_QUIET_ACK;goto failed;}
    cut->ack_end_ns=c->ops.clock_ns(c->ops.user);
    if(cut->ack_end_ns>=deadline) {error=ABC_QUIET_ACK;goto failed;}
    if((error=timed_out(c,cut->enter_ns))) goto failed;
    cut->accepted=1;cut->exit_ns=c->ops.clock_ns(c->ops.user);
    return ABC_QUIET_OK;
failed:
    cut->exit_ns=c->ops.clock_ns(c->ops.user);
    return fail(c,error);
}
