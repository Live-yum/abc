/* Original host adapter around separately supplied circuit-world engine. */
#include "abc_world_circuit.h"
#include "terra_circuit_world.h"
#include "terra_stream.h"
#include <string.h>
extern void* tx_bridge_native_alloc(uint32_t);
extern void tx_bridge_native_free(void*);
_Static_assert(sizeof(((TerraCircuitWorldEvent*)0)->data_ptr)==sizeof(uintptr_t),"Apply private native pointer-safety patch before building");
_Static_assert(sizeof(((TerraCircuitWorldCommand*)0)->data_ptr)==sizeof(uintptr_t),"Apply private native pointer-safety patch before building");
int32_t abc_world_circuit_begin(uint32_t w,uint32_t s,uint32_t b,uint32_t* h){return terra_circuit_world_begin(w,s,b,h);}
int32_t abc_world_circuit_step(uint32_t h,uint32_t work,uint32_t* v,const uint8_t** data){
 if(!v||!data)return -1;TerraCircuitWorldEvent e={0};*data=NULL;
 int32_t s=terra_circuit_world_step(h,work,&e);if(s<0)return s;
 uint32_t out[]={e.abi_version,e.kind,e.source_id,e.offset,e.length,0,e.phase,e.completed,e.total,e.result_kind,e.result_count,e.reserved};
 memcpy(v,out,sizeof(out));*data=(const uint8_t*)e.data_ptr;return s;
}
int32_t abc_world_circuit_supply(uint32_t h,uint32_t s,uint32_t o,const uint8_t* p,uint32_t n){return terra_circuit_world_supply(h,s,o,p,n);}
int32_t abc_world_circuit_ack(uint32_t h){return terra_circuit_world_ack(h);}
int32_t abc_world_circuit_command(uint32_t h,const uint32_t* v,const uint32_t* records){
 if(!v||v[9]||v[14]||v[15]||(!records&&v[10]))return -1;
 TerraCircuitWorldCommand c={0};c.abi_version=v[0];c.kind=v[1];c.x=v[2];c.y=v[3];c.width=v[4];c.height=v[5];c.stride=v[6];c.mask=v[7];c.count=v[8];c.data_ptr=(uintptr_t)records;c.data_count=v[10];c.source_id=v[11];c.flags=v[12];c.aux_source_id=v[13];return terra_circuit_world_command(h,&c);
}
int32_t abc_world_circuit_stats(uint32_t h,uint32_t* words){if(!words)return -1;TerraCircuitWorldStats s={0};int32_t r=terra_circuit_world_stats(h,&s);if(!r)memcpy(words,&s,sizeof(s));return r;}
int32_t abc_world_circuit_cancel(uint32_t h){return terra_circuit_world_cancel(h);}
int32_t abc_world_circuit_close(uint32_t h){return terra_circuit_world_close(h);}
int32_t abc_world_stream_open_begin(uint32_t s,uint32_t n,uint32_t* t){
 if(!t)return -1;*t=0;uint32_t* out=tx_bridge_native_alloc(4);if(!out)return -1;*out=0;
 int32_t r=terra_world_stream_open_begin(s,n,out);if(r>=0)*t=*out;tx_bridge_native_free(out);return r;
}
int32_t abc_world_stream_step(uint32_t t,uint32_t work,uint32_t* v,const uint8_t** data){
 if(!v||!data)return -1;*data=NULL;TxStreamEvent* e=tx_bridge_native_alloc(sizeof(*e));if(!e)return -1;
 int32_t s=terra_world_stream_step(t,work,e);if(s>=0){
 uint32_t out[]={e->abi_version,e->kind,e->source_id,e->offset,e->length,0,e->first_column,e->column_count,e->completed_columns,e->total_columns,e->result_size,e->reserved};
 memcpy(v,out,sizeof(out));*data=(const uint8_t*)e->data_ptr;}
 tx_bridge_native_free(e);return s;
}
int32_t abc_world_stream_supply(uint32_t t,uint32_t s,uint32_t o,const uint8_t* p,uint32_t n){
 if(!p||!n||n>1024u*1024u)return -1;uint8_t* input=tx_bridge_native_alloc(n);if(!input)return -1;
 memcpy(input,p,n);int32_t r=terra_world_stream_supply_source(t,s,o,input,n);tx_bridge_native_free(input);return r;
}
int32_t abc_world_stream_adopt(uint32_t t,uint32_t s,uint32_t* w){
 if(!w)return -1;*w=0;uint32_t* out=tx_bridge_native_alloc(4);if(!out)return -1;*out=0;
 int32_t r=terra_world_stream_adopt(t,s,out);if(r>=0)*w=*out;tx_bridge_native_free(out);return r;
}
int32_t abc_world_stream_cancel(uint32_t t){return terra_world_stream_cancel(t);}
int32_t abc_world_stream_close(uint32_t t){return terra_world_stream_close(t);}
