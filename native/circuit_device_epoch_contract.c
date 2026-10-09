/* Test-only physical button dedup regression for the reviewed epoch patch. */
#include "terra_circuit_world_internal.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void run(uint32_t optimization) {
 CxWorld world;CxDevice devices[4];CxPort ports[8];
 memset(&world,0,sizeof(world));memset(devices,0,sizeof(devices));
 world.optimization=optimization;world.devices=devices;world.device_count=4;world.ports=ports;world.port_count=8;
 for(uint32_t x=0;x<2;x++)for(uint32_t y=0;y<2;y++){
  uint32_t i=x*2u+y;devices[i].x=2+x;devices[i].y=2+y;
  devices[i].tile.active=1;devices[i].tile.type=411;
  devices[i].tile.frame_x=(int16_t)(x*18u);devices[i].tile.frame_y=(int16_t)(y*18u);
  ports[i]=(CxPort){1,i,3,0,0};ports[4+i]=(CxPort){2,i,3,1,0};
 }
 assert(cx_trip_begin(&world)==0);assert(cx_net_hit(&world,0)==0);
 assert(devices[0].tile.frame_x==36&&devices[3].tile.frame_x==54);
 assert(cx_net_hit(&world,0)==0&&devices[0].tile.frame_x==36);
 assert(cx_net_hit(&world,1)==0&&devices[0].tile.frame_x==0);
 assert(cx_trip_begin(&world)==0);assert(cx_net_hit(&world,0)==0&&devices[0].tile.frame_x==36);
 /* Per-activation vm_trip_index resets must not alias the dedup epoch. */
 world.vm_trip_index=0;assert(cx_trip_begin(&world)==0);
 assert(cx_net_hit(&world,0)==0&&devices[0].tile.frame_x==0);
 /* A transaction rollback restores tile state, while transient generations
  * may advance. A new trip must accept the same physical button again. */
 devices[0].tile.frame_x=36;devices[1].tile.frame_x=36;
 devices[2].tile.frame_x=54;devices[3].tile.frame_x=54;
 world.vm_trip_index=0;assert(cx_trip_begin(&world)==0);
 assert(cx_net_hit(&world,0)==0&&devices[0].tile.frame_x==0);
 if(optimization){
 world.wire_trip_epoch=UINT32_MAX;
 for(uint32_t i=0;i<4;i++){devices[i].wire_hit_epoch=1;devices[i].wire_hit_mask=15;}
 assert(cx_trip_begin(&world)==0&&world.wire_trip_epoch==1);
 assert(cx_net_hit(&world,0)==0&&devices[0].tile.frame_x==36);
 }
}
int main(void){run(0);run(1);puts("PASS: both modes, multicolor/multipart button dedup, independent pulses, rollback restart, epoch wrap");return 0;}
