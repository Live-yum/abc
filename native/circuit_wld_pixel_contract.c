/* Original tests of actual retained PixelBox rules. OFF keeps the pinned game
 * TripWire crossing rule; ON pairs different colour groups within one wave. */
#include "terra_circuit_world_internal.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void trip(CxWorld* w,const uint32_t* nets,uint32_t count){
    assert(cx_trip_begin(w)==0);
    for(uint32_t i=0;i<count;i++)assert(cx_net_hit(w,nets[i])==0);
    assert(cx_trip_end(w)==0);
}
static void end_wave(CxWorld* w){assert(cx_pixel_wave_end(w)==0);}
static void setup(CxWorld* w,CxPixel* p,CxPort* ports,uint32_t* touched){
    memset(w,0,sizeof(*w));memset(p,0,sizeof(*p));
    w->phase=CX_IDLE;w->pixels=p;w->pixel_count=1;w->pixel_touched=touched;
    w->ports=ports;w->port_count=4;
    /* Real single-axis wires plus the compiler's disconnected axis labels. */
    p->h[0]=2;p->v[0]=4;p->h[1]=5;p->v[1]=3;
    p->connected_h=1;p->connected_v=2;
    ports[0]=(CxPort){2,0,0,0,0};ports[1]=(CxPort){3,0,1,1,0};
    ports[2]=(CxPort){4,0,1,0,0};ports[3]=(CxPort){5,0,0,1,0};
}
static void basic_rules(void){
    CxWorld w;CxPixel p;CxPort ports[4];uint32_t touched[1];
    const uint32_t h[]={1},v[]={2},cross[]={1,2},same_colour[]={1,3};
    setup(&w,&p,ports,touched);
    trip(&w,h,1);trip(&w,v,1);end_wave(&w);assert(p.state==0);
    trip(&w,cross,2);end_wave(&w);assert(p.state==1);
    trip(&w,same_colour,2);end_wave(&w);assert(p.state==0);
    assert(cx_set_optimization(&w,1)==0&&p.state==0);
    trip(&w,h,1);end_wave(&w);assert(p.state==0);
    trip(&w,v,1);end_wave(&w);assert(p.state==0); /* No cross-wave pair. */
    trip(&w,h,1);trip(&w,v,1);assert(p.state==0);
    end_wave(&w);assert(p.state==1); /* Two gate TripWires in one wave. */
    trip(&w,same_colour,2);end_wave(&w);assert(p.state==1);
    trip(&w,h,1);trip(&w,h,1);trip(&w,v,1);end_wave(&w);
    assert(p.state==1); /* Two red occurrences contribute even pair parity. */
    trip(&w,h,1);trip(&w,h,1);trip(&w,h,1);trip(&w,v,1);end_wave(&w);
    assert(p.state==0);
    trip(&w,cross,2);end_wave(&w);assert(p.state==1);
    uint32_t rng_before=w.rng_i;w.wire_trip_epoch=97;
    assert(cx_set_optimization(&w,0)==0&&p.state==1&&w.rng_i==rng_before);
    assert(!p.hit_h&&!p.hit_v&&!p.marked&&!w.pixel_touched_count&&!w.wire_trip_epoch);
    assert(cx_set_optimization(&w,1)==0&&p.state==1);
    w.phase=CX_RUN;assert(cx_set_optimization(&w,0)==TCW_STATE&&w.optimization==1&&p.state==1);
    w.phase=CX_IDLE;w.pixel_compat_unsupported=1;
    assert(cx_set_optimization(&w,0)==0);
    assert(cx_set_optimization(&w,1)==TCW_UNSUPPORTED&&!w.optimization&&p.state==1&&w.phase==CX_IDLE);
    w.pixel_count=0;w.pixel_compat_unsupported=0;
    assert(cx_set_optimization(&w,1)==0); /* No-pixel worlds retain dedup. */
}
static void port_parity(void){
    CxWorld w;CxPixel p;CxPort ports[8];uint32_t touched[1];
    setup(&w,&p,ports,touched);w.port_count=8;p.connected_h=15;p.connected_v=15;
    for(uint32_t c=0;c<4;c++){
        p.h[c]=p.v[c]=c+1;
        ports[2*c]=(CxPort){c+1,0,0,(uint8_t)c,0};
        ports[2*c+1]=(CxPort){c+1,0,1,(uint8_t)c,0};
    }
    assert(cx_pixel_topology_supported(&p));assert(cx_set_optimization(&w,1)==0);
    const uint32_t two[]={0,1},three[]={0,1,2},four[]={0,1,2,3};
    trip(&w,two,2);end_wave(&w);assert(p.state==1); /* Duplicate H/V ports count once. */
    trip(&w,three,3);end_wave(&w);assert(p.state==0); /* Three pairs. */
    trip(&w,four,4);end_wave(&w);assert(p.state==0); /* Six pairs. */
    p.v[0]=99;assert(!cx_pixel_topology_supported(&p));
    p.connected_v&=(uint8_t)~1u;assert(cx_pixel_topology_supported(&p));
    /* An entirely isolated colour keeps one canonical seed, not two groups. */
    p.connected_h=p.connected_v=0;p.h[0]=5;p.v[0]=1;
    p.h[1]=6;p.v[1]=2;w.port_count=4;
    ports[0]=(CxPort){1,0,1,0,0};ports[1]=(CxPort){2,0,1,1,0};
    ports[2]=(CxPort){5,0,0,0,0};ports[3]=(CxPort){6,0,0,1,0};
    trip(&w,two,2);end_wave(&w);assert(p.state==1);
}
static int32_t next_candidate(void* context,uint32_t net,uint32_t* cursor,TerraVmGateRef* out){
    (void)context;if(net!=0||*cursor>=2)return 0;
    *out=(TerraVmGateRef){0,++*cursor};return 1;
}
static int32_t evaluate(void* context,TerraVmGateRef event,const TerraCircuitVm* vm,TerraVmGateResult* out){
    CxWorld* w=context;(void)vm;memset(out,0,sizeof(*out));out->identity=event;
    if(w->command.mask){if(event.offset!=1)return 0;out->count=2;out->nets[0]=1;out->nets[1]=2;}
    else {out->count=1;out->nets[0]=event.offset;}
    return 1;
}
static void yielded_gate_waves(uint32_t optimized){
    CxWorld w;CxPixel p;CxPort ports[4];uint32_t touched[1];setup(&w,&p,ports,touched);
    assert(cx_set_optimization(&w,optimized)==0);
    TerraVmCallbacks cb={0};cb.next_candidate=next_candidate;cb.evaluate=evaluate;
    cb.trip_begin=cx_trip_begin;cb.net_hit=cx_net_hit;cb.trip_end=cx_trip_end;cb.wave_end=cx_pixel_wave_end;
    assert(terra_vm_create(5,1024u*1024u,&cb,&w,&w.vm)==0);
    uint32_t seed=0;assert(terra_vm_begin(w.vm,&seed,1)==TERRA_VM_MORE);int status;
    do {status=terra_vm_step(w.vm,1);}while(status==TERRA_VM_MORE);
    assert(status==TERRA_VM_OK&&p.state==optimized);
    TerraVmStats stats;terra_vm_stats(w.vm,&stats);assert(stats.gates_fired==2);
    w.command.mask=1;assert(terra_vm_begin(w.vm,&seed,1)==TERRA_VM_MORE);
    do {status=terra_vm_step(w.vm,1);}while(status==TERRA_VM_MORE);
    assert(status==TERRA_VM_OK&&p.state==(optimized^1u));
    terra_vm_destroy(w.vm);
}
static void actual_rule_rollback(void){
    CxWorld w;CxPixel p;CxPort ports[4];uint32_t touched[1];setup(&w,&p,ports,touched);
    TxWorld source={0};uint8_t action_bits[1]={0},snapshot[1]={0};uint32_t mechs[1]={0},saved[1]={0};
    w.world=&source;w.maximum=1024u*1024u;w.networks=5;w.action_bits=action_bits;
    w.pixel_snapshot=snapshot;w.mechs=mechs;w.mechs_snapshot=saved;
    assert(cx_set_optimization(&w,1)==0);assert(cx_create_vm(&w)==0);
    const uint32_t seeds[]={1,2};assert(terra_vm_begin(w.vm,seeds,2)==TERRA_VM_MORE);
    for(int i=0;i<100&&p.hit_h!=3;i++)assert(terra_vm_step(w.vm,1)==TERRA_VM_MORE);
    assert(p.hit_h==3&&p.state==0);
    terra_vm_cancel(w.vm); /* Uses the production transaction_rollback callback. */
    assert(p.state==0&&!p.hit_h&&!p.hit_v&&!p.marked&&!w.pixel_touched_count);
    assert(terra_vm_begin(w.vm,seeds,2)==TERRA_VM_MORE);int status;
    do {status=terra_vm_step(w.vm,1);}while(status==TERRA_VM_MORE);
    assert(status==TERRA_VM_OK&&p.state==1);
    assert(cx_operation_begin(&w)==TCW_OK);
    assert(terra_vm_begin(w.vm,seeds,2)==TERRA_VM_MORE);
    do {status=terra_vm_step(w.vm,1);}while(status==TERRA_VM_MORE);
    assert(status==TERRA_VM_OK&&p.state==0);
    assert(terra_vm_begin(w.vm,seeds,2)==TERRA_VM_MORE);
    for(int i=0;i<100&&!p.hit_h;i++)assert(terra_vm_step(w.vm,1)==TERRA_VM_MORE);
    cx_operation_rollback(&w); /* Cancel an atomic batch after an earlier full pulse. */
    assert(p.state==1&&!p.hit_h&&!p.hit_v&&!p.marked&&!w.pixel_touched_count);
    assert(!w.operation_active);
    terra_vm_destroy(w.vm);w.vm=NULL;cx_free(&w,w.general_snapshot);
}
int main(void){
    basic_rules();port_parity();yielded_gate_waves(0);yielded_gate_waves(1);actual_rule_rollback();
    puts("PASS: vanilla TripWire crossings; optimized cross-colour wave parity, duplicate/stub ports, topology rejection, idle switches, yielded gates and actual rollback/restart");
    return 0;
}
