/* Original source-behavior assertions for vertical vanilla light footprints. */
#include "terra_circuit_world_internal.h"
#include "terra_circuit_actuation.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void run(uint32_t type,uint32_t height,uint32_t optimized){
    CxWorld w={0};CxDevice devices[3]={0};CxPort ports[6]={0};
    w.width=20;w.height=32;w.devices=devices;w.device_count=height;
    w.ports=ports;w.port_count=height*2;w.optimization=optimized;
    w.seed_x=3;w.seed_y=10;w.seed_width=w.seed_height=1;
    assert(cx_wired_light_height(type)==height);
    assert(!cx_actuatable_type(type));
    for(uint32_t row=0;row<height;row++){
        CxDevice* d=devices+row;d->x=6;d->y=10+row;
        d->tile.active=1;d->tile.type=(uint16_t)type;d->tile.actuator=1;
        d->tile.frame_y=(int16_t)((height*5u+row)*18u);
        ports[row]=(CxPort){1,row,6,0,0};
        ports[height+row]=(CxPort){2,row,6,1,0};
    }
    assert(cx_trip_begin(&w)==0&&cx_net_hit(&w,0)==0);
    for(uint32_t row=0;row<height;row++){
        assert(devices[row].tile.frame_x==18);
        assert(devices[row].tile.frame_y==(int16_t)((height*5u+row)*18u));
        assert(!devices[row].tile.inactive&&devices[row].tile.actuator);
    }
    assert(cx_net_hit(&w,0)==0&&devices[0].tile.frame_x==18);
    assert(cx_net_hit(&w,1)==0&&devices[0].tile.frame_x==0);
    assert(cx_trip_end(&w)==0);
    w.vm_trip_index=0;w.seed_x=6;w.seed_height=height;
    assert(cx_trip_begin(&w)==0&&cx_net_hit(&w,0)==0);
    assert(devices[0].tile.frame_x==0); /* All source cells are skipped. */
    assert(cx_trip_end(&w)==0);
    w.vm_trip_index=0;w.seed_height=1;
    assert(cx_trip_begin(&w)==0&&cx_net_hit(&w,0)==0);
    assert(devices[0].tile.frame_x==18); /* A nonseed sibling still acts. */
    assert(cx_trip_end(&w)==0);
    w.vm_trip_index=0;w.seed_x=3;
    devices[height-1].tile.frame_y+=18;
    assert(cx_trip_begin(&w)==0&&cx_net_hit(&w,0)==TCW_UNSUPPORTED);
    for(uint32_t row=0;row<height;row++)assert(devices[row].tile.frame_x==18);
}

int main(void){
    for(uint32_t mode=0;mode<2;mode++){run(42,2,mode);run(93,3,mode);}
    puts("PASS: 42/93 light footprint state, colour dedup, seed skip, normal actuators and malformed preflight");
    return 0;
}
