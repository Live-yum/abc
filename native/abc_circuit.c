#include "abc_circuit.h"
#include "terra_circuit.h"
#include <stdlib.h>

int32_t abc_circuit_propagate(uint32_t width,uint32_t height,
 const uint32_t* cells,uint32_t count,uint32_t x,uint32_t y,uint32_t colour,
 uint32_t* reached,uint32_t capacity,uint32_t* out_count) {
 if(!out_count || !width || !height || width>256 || height>256 ||
    count>65536 || colour>3 || x>=width || y>=height ||
    (count && (!cells || !reached)) || capacity<count) return -1;
 *out_count=0;
 if(!count) return 0;
 for(uint32_t i=0;i<count;i++) if(cells[i*4+3]>1) return -1;
 uint32_t handle=0,compiled=0,written=0;
 int32_t status=terra_circuit_create(width,height,count,16u*1024u*1024u,&handle);
 if(status<0) return status;
 uint8_t* seen=calloc((size_t)width*height,1);
 if(!seen) {terra_circuit_close(handle);return -5;}
 status=terra_circuit_load(handle,(const TerraCircuitCell*)cells,count);
 if(status<0) goto done;
 do {status=terra_circuit_compile(handle,65536,&compiled);} while(status==1);
 if(status<0) goto done;
 TerraCircuitPoint seed={x,y};
 status=terra_circuit_begin(handle,&seed,1,colour,TERRA_CIRCUIT_TRACE,count*8u+64u);
 if(status<0) goto done;
 do {
   TerraCircuitEvent events[256]; TerraCircuitStep step={0};
   status=terra_circuit_step(handle,256,events,256,&step);
   if(status<0) break;
   for(uint32_t i=0;i<step.emitted;i++) {
     uint32_t index=events[i].y*width+events[i].x;
     if(!seen[index]) {seen[index]=1;reached[written++]=index;}
   }
 } while(status==1);
 if(status==0) *out_count=written;
 done:
 free(seen); terra_circuit_close(handle); return status;
}
