/* Original pointer-safe host facade. Engine sources remain separately supplied.
 * All calls MUST be serialized on one owning thread/isolate. Output buffers are
 * caller-owned; NULL/0 probes return required size, including JSON trailing NUL.
 * Never call tx_malloc/tx_free from a 64-bit host: that legacy ABI is Wasm32-only.
 */
#include "abc_engine.h"
#include "terra_abi.h"
#include "terra_world.h"
#include "terra_plr.h"
#include <stdlib.h>
#include <limits.h>
uint32_t abc_engine_abi_version(void){ return 1; }
const char* abc_engine_build_info(void){ return terra_build_info_json(); }
void* abc_alloc(size_t size){ return size ? malloc(size) : NULL; }
void abc_free(void* p){ free(p); }
static int32_t result(int32_t status,uint64_t size,uint32_t* required){
 if(required) *required=size<=UINT32_MAX?(uint32_t)size:0;
 return size>UINT32_MAX?TERRAX_WORLD_STATUS_INTERNAL_ERROR:status;
}
int32_t abc_error(char* out,uint32_t cap,uint32_t* required){
 uint64_t n=0; int32_t s=terra_info_get_last_error_json(out,cap,&n); return result(s,n,required);
}
int32_t abc_world_open(const uint8_t* p,uint32_t n,uint32_t* h){ return terra_world_open_from_buffer(p,n,h); }
int32_t abc_world_close(uint32_t h){ return terra_world_close(h); }
int32_t abc_world_section(uint32_t h,const char* key,char* out,uint32_t cap,uint32_t* required){
 uint64_t n=0; int32_t s=terra_section_get_json(h,key,out,cap,&n); return result(s,n,required);
}
int32_t abc_world_operation(uint32_t h,const char* op,const char* json,char* out,uint32_t cap,uint32_t* required){
 uint64_t n=0; int32_t s=terra_op_execute_json(h,op,json,out,cap,&n); return result(s,n,required);
}
int32_t abc_world_save(uint32_t h,uint8_t* p,uint32_t n,uint32_t* r){ return terra_world_save_to_buffer(h,p,n,r); }
int32_t abc_world_thumbnail(uint32_t h,uint8_t* p,uint32_t cap,uint32_t* required,uint32_t* w,uint32_t* height){
 uint64_t n=0; int32_t s=terra_op_get_thumbnail_png(h,p,cap,&n,w,height); return result(s==2 && !p && !cap ? 0 : s,n,required);
}
int32_t abc_world_map(uint32_t h,uint8_t* p,uint32_t cap,uint32_t* required,uint32_t* w,uint32_t* height){
 uint64_t n=0; int32_t s=terra_op_get_map(h,p,cap,&n,w,height); return result(s==2 && !p && !cap ? 0 : s,n,required);
}
int32_t abc_player_open(const uint8_t* p,uint32_t n,uint32_t* h){ return terra_plr_open_from_buffer(p,n,h); }
int32_t abc_player_open_json(const char* json,uint32_t* handle){ return terra_plr_open_json(json,handle); }
int32_t abc_player_set_many(uint32_t h,const char* edits){ return terra_plr_set_many(h,edits); }
int32_t abc_player_close(uint32_t h){ return terra_plr_close(h); }
int32_t abc_player_json(uint32_t h,char* p,uint32_t n,uint32_t* r){ return terra_plr_get_json(h,p,n,r); }
int32_t abc_player_set(uint32_t h,const char* pointer,const char* json){ return terra_plr_set(h,pointer,json); }
int32_t abc_player_patch(uint32_t h,const char* json){ return terra_plr_apply_patch_json(h,json); }
int32_t abc_player_save(uint32_t h,uint8_t* p,uint32_t n,uint32_t* r){ return terra_plr_save_to_buffer(h,p,n,r); }
