/* Original host adapter for the upstream validated sparse candidate writer. */
#include "abc_region.h"
#include "terra_stream.h"
#include "terra_world.h"
#include "terra_types.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
extern void* tx_bridge_native_alloc(uint32_t);
extern void tx_bridge_native_free(void*);
extern TxWorld* tx_get_world(uint32_t);
extern int read_tile_at(TxWorld*,uint32_t*,uint32_t,TxTile*);
extern void tx_set_error(const char*,const char*);
extern char tx_last_error[256];
extern int32_t tx_last_status;
static void close_world(uint32_t h){char error[256];memcpy(error,tx_last_error,256);int32_t status=tx_last_status;terra_world_close(h);if(error[0]){memcpy(tx_last_error,error,256);tx_last_status=status;}}
static void close_task(uint32_t h){char error[256];memcpy(error,tx_last_error,256);int32_t status=tx_last_status;terra_world_stream_close(h);if(error[0]){memcpy(tx_last_error,error,256);tx_last_status=status;}}
#define LIMIT (512u*1024u*1024u)
typedef struct {const uint8_t* p;uint32_t n;} Source;
static int bad(const char* message){tx_set_error("ABC_REGION_INVALID",message);return -1;}
static void* bridge(const void* p,uint32_t n){void* q=tx_bridge_native_alloc(n);if(q&&p)memcpy(q,p,n);return q;}
static int pump(uint32_t task,Source* sources,uint8_t** output,uint32_t* size,const uint16_t* indices,uint32_t width,uint32_t height){
 TxStreamEvent* e=bridge(NULL,sizeof(*e));uint8_t* input=bridge(NULL,1024*1024);int status=-1;
 if(!e||!input)goto done;
 for(;;){if(terra_world_stream_step(task,4096,e)<0)goto done;
  if(e->kind==TX_STREAM_MORE)continue;
  if(e->kind==TX_STREAM_READY){status=0;break;}
  if(e->kind==TX_STREAM_NEED_SOURCE){
   if(e->source_id>3||e->source_id==0)goto invalid;Source s=sources[e->source_id];
   if(e->offset>s.n||e->length>s.n-e->offset||e->length>1024*1024)goto invalid;
   memcpy(input,s.p+e->offset,e->length);
   if(terra_world_stream_supply_source(task,e->source_id,e->offset,input,e->length)<0)goto done;
  }else if(e->kind==TX_STREAM_OUTPUT){
   if(!output||!size||e->offset>LIMIT||e->length>LIMIT-e->offset)goto invalid;
   uint32_t end=e->offset+e->length;if(end>*size){void* q=realloc(*output,end);if(!q)goto done;*output=q;if(e->offset>*size)memset(*output+*size,0,e->offset-*size);*size=end;}
   memcpy(*output+e->offset,(const void*)e->data_ptr,e->length);
   if(terra_world_stream_ack_output(task)<0)goto done;
  }else if(e->kind==TX_STREAM_NEED_PIXELS){
   if(!indices)goto invalid;uint32_t rows=(height+63)/64,cx=e->first_column/64,count=0;
   if(rows>LIMIT/8200)goto invalid;
   uint8_t* records=bridge(NULL,rows*8200);if(!records)goto done;memset(records,0,rows*8200);
   for(uint32_t cy=0;cy<rows;cy++){uint16_t* r=(uint16_t*)(records+count*8200);uint32_t used=0;r[0]=cx;r[1]=cy;
    for(uint32_t yy=0;yy<64;yy++)for(uint32_t xx=0;xx<64;xx++){uint32_t x=cx*64+xx,y=cy*64+yy;uint16_t v=x<width&&y<height?indices[y*width+x]:0;r[4+yy*64+xx]=v;used+=v!=0;}
    r[2]=used;if(used)count++;
   }
   int r=terra_world_stream_supply_pixels(task,records,count*8200,count);tx_bridge_native_free(records);if(r<0)goto done;
  }else goto invalid;
 }
 goto done;
 invalid:bad("Invalid stream range/event; original world preserved");
 done:tx_bridge_native_free(e);tx_bridge_native_free(input);return status;
}
static int open_stream(Source* sources,uint32_t* world){
 uint32_t* id=bridge(NULL,4);int result=-1;if(!id)return -1;*id=0;
 if(terra_world_stream_open_begin(1,sources[1].n,id)<0)goto done;
 if(pump(*id,sources,NULL,NULL,NULL,0,0)<0)goto close;
 uint32_t* out=bridge(NULL,4);if(!out)goto close;
 result=terra_world_stream_adopt(*id,1,out);if(!result)*world=*out;tx_bridge_native_free(out);
 close:close_task(*id);
 done:tx_bridge_native_free(id);return result;
}
int32_t abc_region_operation(const uint8_t* bytes,uint32_t n,const char* operation,const char* json,const uint8_t* records,uint32_t rn,const uint8_t* objects,uint32_t on,uint8_t** output,uint32_t* size){
 if(!bytes||!n||!output||!size||!operation||!json)return bad("Missing region operation input");*output=NULL;*size=0;
 Source sources[4]={{0},{bytes,n},{records,rn},{objects,on}};uint32_t world=0;int result=-1;
 uint32_t* task=bridge(NULL,4);char* op=bridge(operation,strlen(operation)+1);char* request=bridge(json,strlen(json)+1);
 if(!task||!op||!request)goto done;*task=0;
 if(open_stream(sources,&world)<0)goto done;
 if(terra_world_stream_operation_begin(world,op,request,task)<0)goto done;
 result=pump(*task,sources,output,size,NULL,0,0);close_task(*task);
 done:if(world)close_world(world);tx_bridge_native_free(task);tx_bridge_native_free(op);tx_bridge_native_free(request);
 if(result){free(*output);*output=NULL;*size=0;}return result;
}
static int pixel_preflight(const uint8_t*,uint32_t,int32_t,int32_t,uint32_t,uint32_t,const uint8_t*,uint32_t,const uint16_t*);
static int32_t abc_region_pixel_legacy_internal(const uint8_t* bytes,uint32_t n,int32_t x,int32_t y,uint32_t width,uint32_t height,const uint8_t* maps,uint32_t map_count,const uint16_t* indices,uint8_t** output,uint32_t* size){
 if(!bytes||!n||!output||!size||!maps||!indices||!width||!height||width>16384||height>16384||!map_count||map_count>65536)return bad("Invalid pixel dimensions or palette");
 *output=NULL;*size=0;if(pixel_preflight(bytes,n,x,y,width,height,maps,map_count,indices))return -1;Source sources[4]={{0},{bytes,n},{0},{0}};uint32_t world=0;int result=-1;
 uint32_t* task=bridge(NULL,4);TxStreamPixelSpec* spec=bridge(NULL,sizeof(*spec));void* palette=bridge(maps,map_count*12);
 if(!task||!spec||!palette)goto done;*task=0;memset(spec,0,sizeof(*spec));spec->abi_version=1;spec->start_x=x;spec->start_y=y;spec->width=width;spec->height=height;spec->resolved_maps_ptr=(uintptr_t)palette;spec->resolved_maps_count=map_count;
 if(open_stream(sources,&world)<0)goto done;
 if(terra_world_stream_pixel_begin(world,spec,task)<0)goto done;
 result=pump(*task,sources,output,size,indices,width,height);close_task(*task);
 done:if(world)close_world(world);tx_bridge_native_free(task);tx_bridge_native_free(spec);tx_bridge_native_free(palette);if(result){free(*output);*output=NULL;*size=0;}return result;
}
/* Complete tile-layer records, column-major, relative coordinates; same 32-byte
 * format as TCW_EXTRACT/stamp_tiles. Metadata is preserved by the core writer. */
int32_t abc_region_read(const uint8_t* bytes,uint32_t n,uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint8_t** output,uint32_t* size){
 if(!output||!size)return -1;*output=NULL;*size=0;uint32_t h=0;int status=-1;
 if(!width||!height||(uint64_t)width*height>262144)return bad("Region must contain 1..262144 cells");
 if(terra_world_open_from_buffer(bytes,n,&h))return -1;TxWorld* w=tx_get_world(h);
 if(!w||w->legacy_wld||x>=(uint32_t)w->maxTilesX||y>=(uint32_t)w->maxTilesY||width>(uint32_t)w->maxTilesX-x||height>(uint32_t)w->maxTilesY-y){bad("Region outside modern WLD bounds");goto done;}
 uint32_t* out=malloc(width*height*32);if(!out)goto done;uint32_t off=w->starts[1],at=0;
 for(uint32_t xx=0;xx<x+width;xx++){uint32_t yy=0;while(yy<(uint32_t)w->maxTilesY){TxTile t;if(!read_tile_at(w,&off,w->ends[1],&t))goto fail;uint32_t run=(uint32_t)t.same+1;if(run>(uint32_t)w->maxTilesY-yy)goto fail;
  if(xx>=x)for(uint32_t py=yy>y?yy:y;py<yy+run&&py<y+height;py++){uint32_t f=t.active|(t.actuator<<1)|(t.inactive<<2)|(t.invisible_block<<3)|(t.invisible_wall<<4)|(t.fullbright_block<<5)|(t.fullbright_wall<<6);uint32_t wires=t.wire_red|(t.wire_blue<<1)|(t.wire_green<<2)|(t.wire_yellow<<3);uint32_t* r=out+at*8;r[0]=xx-x;r[1]=py-y;r[2]=t.type|(f<<16);r[3]=(uint16_t)t.frame_x|((uint32_t)(uint16_t)t.frame_y<<16);r[4]=t.wall|(t.tile_color<<16)|((uint32_t)t.wall_color<<24);r[5]=t.liquid_amount|(t.liquid_type<<8)|(t.brick_style<<16)|(wires<<24);r[6]=r[7]=0;at++;}yy+=run;}}
 *output=(uint8_t*)out;*size=at*32;status=0;goto done;
 fail:free(out);bad("Invalid tile records");
 done:close_world(h);return status;
}
ABC_EXPORT void abc_region_free(void* p){free(p);}
#include "terra_circuit_objects.h"
#include "terra_tile_record.h"
extern void buf_init(TxBuf*,uint32_t);
extern void write_tile(TxWorld*,TxBuf*,const TxTile*,uint32_t);
extern int set_section_override_data(TxWorld*,int,uint8_t*,uint32_t);
extern void tx_internal_free(void*);
int32_t abc_region_objects(const uint8_t* bytes,uint32_t n,uint32_t x,uint32_t y,uint32_t width,uint32_t height,uint8_t** output,uint32_t* size){
 if(!output||!size)return -1;*output=NULL;*size=0;uint8_t* records=NULL;uint32_t rn=0,h=0;int result=-1;
 if(abc_region_read(bytes,n,x,y,width,height,&records,&rn))return -1;
 if(terra_world_open_from_buffer(bytes,n,&h))goto done;TxWorld* w=tx_get_world(h);
 if(w->version<88||w->version>326){bad("Object transfer supports WLD 88..326 only");goto done;}
 CoItem* items=calloc(CO_COUNT,sizeof(CoItem));uint32_t count=0,total=32;if(!items)goto done;
 for(uint32_t i=0;i<rn/32;i++){uint32_t* r=(uint32_t*)records+i*8;TxTile t;if(!tx_tile_unrecord(r,&t))goto fail;
  if(!t.active||!co_section(t.type))continue;
  if(co_root_frame(t.type,t.frame_x,t.frame_y)){
   uint32_t shape=co_shape(t.type),ww=shape&255,hh=shape>>8;
   if(!ww||!hh||ww>width-r[0]||hh>height-r[1]||count==CO_COUNT)goto incomplete;
   for(uint32_t dx=0;dx<ww;dx++)for(uint32_t dy=0;dy<hh;dy++){uint32_t* c=(uint32_t*)records+((r[0]+dx)*height+r[1]+dy)*8;TxTile cell;if(!tx_tile_unrecord(c,&cell)||!cell.active||cell.type!=t.type||cell.frame_x!=t.frame_x+(int32_t)dx*18||cell.frame_y!=t.frame_y+(int32_t)dy*18)goto incomplete;}
   items[count].x=x+r[0];items[count].y=y+r[1];items[count].tile=t.type;count++;
  }else{ /* Every section-backed cell must belong to an included root. */
   uint32_t shape=co_shape(t.type),ww=shape&255,hh=shape>>8;if(!ww||!hh||t.frame_x<0||t.frame_y<0)goto incomplete;
   uint32_t dx=((uint32_t)t.frame_x/18)%ww,dy=((uint32_t)t.frame_y/18)%hh;
   if(dx>r[0]||dy>r[1])goto incomplete;
  }
 }
 for(uint32_t i=0;i<rn/32;i++){uint32_t* r=(uint32_t*)records+i*8;TxTile t;tx_tile_unrecord(r,&t);if(!t.active||!co_section(t.type))continue;
  uint32_t shape=co_shape(t.type),ww=shape&255,hh=shape>>8;if(!ww||!hh||t.frame_x<0||t.frame_y<0)goto incomplete;
  uint32_t dx=((uint32_t)t.frame_x/18)%ww,dy=((uint32_t)t.frame_y/18)%hh;if(dx>r[0]||dy>r[1])goto incomplete;
  CoItem* owner=co_find(items,count,x+r[0]-dx,y+r[1]-dy);if(!owner||owner->tile!=t.type)goto incomplete;
 }
 for(uint32_t section=2;section<=5;section++){if(section==4)continue;CoCursor cursor;if(!co_cursor(w,section,&cursor))goto malformed;CoItem value;int next;
  while((next=co_next(&cursor,&value))==1){CoItem* item=co_find(items,count,value.x,value.y);if(!item)continue;if(item->seen||co_section(item->tile)!=section||(section==5&&item->tile!=value.tile))goto malformed;uint32_t tile=item->tile;*item=value;item->tile=tile;item->seen=1;uint32_t len=co_encode_payload(item,NULL,326);if(len>CO_LIMIT-total||32>CO_LIMIT-total-len)goto malformed;total+=32+len;}
  if(next!=2)goto malformed;
 }
 for(uint32_t i=0;i<count;i++)if(!items[i].seen)goto malformed;
 uint8_t* out=malloc(total);if(!out)goto fail;uint32_t header[]={CO_MAGIC,1,w->version,count,total,x,y,0};for(uint32_t i=0;i<8;i++)co_put(out+i*4,header[i]);uint32_t off=32;
 for(uint32_t i=0;i<count;i++){CoItem* a=items+i;uint32_t len=co_encode_payload(a,NULL,326);uint32_t fields[]={a->section,a->kind,a->x-x,a->y-y,a->tile,len,0,0};for(uint32_t k=0;k<8;k++)co_put(out+off+k*4,fields[k]);co_encode_payload(a,out+off+32,326);off+=32+len;}
 *output=out;*size=total;result=0;goto fail;
 incomplete:bad("Region cuts or contains unsupported section-backed object geometry; expand selection");goto fail;
 malformed:bad("Object sections missing, duplicate, malformed or over 4 MiB");
 fail:free(items);
 done:free(records);if(h)close_world(h);return result;
}
int32_t abc_region_replace(const uint8_t* bytes,uint32_t n,uint32_t x,uint32_t y,uint32_t width,uint32_t height,const uint8_t* records,uint32_t rn,uint8_t** output,uint32_t* size){
 if(!output||!size)return -1;*output=NULL;*size=0;if(!width||!height||(uint64_t)width*height>262144||(uint64_t)width*height*32!=rn||!records)return bad("Replacement requires a complete bounded column-major region");
 uint32_t h=0;int result=-1;TxBuf tiles={0};if(terra_world_open_from_buffer(bytes,n,&h))return -1;TxWorld* w=tx_get_world(h);
 if(!w||w->legacy_wld||!tx_world_require_writable(w)||x>=(uint32_t)w->maxTilesX||y>=(uint32_t)w->maxTilesY||width>(uint32_t)w->maxTilesX-x||height>(uint32_t)w->maxTilesY-y)goto invalid;
 uint32_t off=w->starts[1];buf_init(&tiles,w->ends[1]-off+1024);if(!tiles.ok)goto done;
 for(uint32_t xx=0;xx<(uint32_t)w->maxTilesX;xx++){uint32_t yy=0;while(yy<(uint32_t)w->maxTilesY){TxTile old;if(!read_tile_at(w,&off,w->ends[1],&old))goto invalid;uint32_t run=(uint32_t)old.same+1;if(run>(uint32_t)w->maxTilesY-yy)goto invalid;
  while(run){uint32_t count=run;TxTile tile=old;
   if(xx>=x&&xx<x+width){if(yy<y&&y-yy<count)count=y-yy;else if(yy>=y&&yy<y+height){count=1;uint32_t r[8];memcpy(r,records+((xx-x)*height+yy-y)*32,32);if(r[0]!=xx-x||r[1]!=yy-y||!tx_tile_unrecord(r,&tile))goto invalid;
    if(tile.active&&(tile.type>=w->tile_type_count||tile.type==0xfffeu))goto invalid;
    if(w->version<269&&(tile.liquid_type==4||tile.invisible_block||tile.invisible_wall||tile.fullbright_block||tile.fullbright_wall))goto invalid;
    int oldObject=old.active&&(tx_tile_framed(w,old.type)||tx_tile_needs_section(old.type));int newObject=tile.active&&(tx_tile_framed(w,tile.type)||tx_tile_needs_section(tile.type));
    if((oldObject||newObject)&&(!old.active||!tile.active||old.type!=tile.type||old.frame_x!=tile.frame_x||old.frame_y!=tile.frame_y||old.brick_style!=tile.brick_style)) {bad("Structural furniture/entity changes require validated object placement; original world retained");goto done;}
   }}
   write_tile(w,&tiles,&tile,count-1);if(!tiles.ok||tiles.len>LIMIT)goto done;yy+=count;run-=count;
  }
 }}
 if(!set_section_override_data(w,1,tiles.data,tiles.len))goto done;tiles.data=NULL;
 uint32_t required=0;int status=terra_world_save_to_buffer(h,NULL,0,&required);if(status!=0&&status!=2)goto done;
 uint8_t* out=malloc(required);if(!out)goto done;if(terra_world_save_to_buffer(h,out,required,&required)){free(out);goto done;}
 *output=out;*size=required;result=0;goto done;
 invalid:bad("Invalid region replacement, layers or world bounds");
 done:if(tiles.data)tx_internal_free(tiles.data);close_world(h);return result;
}
#include "terra_pixel_workspace.h"
ABC_EXPORT int32_t abc_region_match(const uint32_t* candidates,uint32_t candidate_count,const uint32_t* rgb,uint32_t count,uint32_t flags,uint32_t* out){
 return terra_pixel_workspace_match_colors((const TerraPixelCandidate*)candidates,candidate_count,rgb,count,flags,out);
}

static int pixel_preflight(const uint8_t* bytes,uint32_t n,int32_t x,int32_t y,uint32_t width,uint32_t height,const uint8_t* maps,uint32_t map_count,const uint16_t* indices){
 uint32_t h=0;int result=-1;if(terra_world_open_from_buffer(bytes,n,&h))return -1;TxWorld* w=tx_get_world(h);
 if(!w||w->legacy_wld||!tx_world_require_writable(w))goto done;
 for(uint32_t i=0;i<map_count;i++){const uint8_t* p=maps+i*12;uint32_t tile=p[4]|((uint32_t)p[5]<<8);if(p[10]>4||p[11]>1||(p[10]==1&&!tile))goto invalid;
  if((p[10]==1||p[10]==4)&&(tile>=w->tile_type_count||tx_tile_framed(w,tile)||tx_tile_needs_section(tile)))goto invalid;
 }
 for(uint64_t i=0;i<(uint64_t)width*height;i++)if(indices[i]>=map_count)goto invalid;
 uint32_t off=w->starts[1];for(uint32_t xx=0;xx<(uint32_t)w->maxTilesX;xx++){uint32_t yy=0;while(yy<(uint32_t)w->maxTilesY){TxTile t;if(!read_tile_at(w,&off,w->ends[1],&t))goto invalid;uint32_t run=(uint32_t)t.same+1;if(run>(uint32_t)w->maxTilesY-yy)goto invalid;
  if((int64_t)xx>=x&&(int64_t)xx<(int64_t)x+width){for(uint32_t dy=0;dy<run;dy++){int64_t py=(int64_t)yy+dy-y;if(py>=0&&py<height){uint16_t index=indices[(uint64_t)py*width+(uint32_t)((int64_t)xx-x)];if(index&&maps[index*12+10]!=3){
   const uint8_t* map=maps+index*12;uint32_t mode=map[10];
   if(t.active&&(tx_tile_framed(w,t.type)||tx_tile_needs_section(t.type))){bad("Pixel insertion intersects existing furniture/entity; choose an empty area");goto done;}
   if(t.liquid_amount||t.wire_red||t.wire_blue||t.wire_green||t.wire_yellow||t.actuator||t.brick_style||t.invisible_block||t.invisible_wall||t.fullbright_block||t.fullbright_wall||(t.inactive&&(!(mode==1||mode==4)||!map[11]))||(mode==1&&t.wall)||(mode==2&&t.active)){
    bad("Pixel core would clear an unrelated existing layer; use exact region replacement or choose an empty area");goto done;
   }
  }}}}

  yy+=run;
 }}result=0;goto done;
 invalid:bad("Invalid pixel mapping or unsupported framed material");
 done:close_world(h);return result;
}

/* Public pixel adapter: merge only requested layers, then the same authoritative
 * structural checks and serializer as exact region editing. No legacy memset. */
int32_t abc_region_pixel(const uint8_t* bytes,uint32_t n,int32_t x,int32_t y,uint32_t width,uint32_t height,const uint8_t* maps,uint32_t map_count,const uint16_t* indices,uint8_t** output,uint32_t* size){
 if(!output||!size)return -1;*output=NULL;*size=0;
 if(!bytes||!n||!maps||!indices||x<0||y<0||!width||!height||width>16384||height>16384||(uint64_t)width*height>262144||!map_count||map_count>65536)return bad("Pixel placement requires a fully in-bounds region of at most 262144 cells");
 uint32_t handle=0;if(terra_world_open_from_buffer(bytes,n,&handle))return -1;TxWorld* w=tx_get_world(handle);int valid=w&&!w->legacy_wld&&tx_world_require_writable(w);
 if(valid)for(uint32_t i=0;i<map_count;i++){const uint8_t* m=maps+i*12;uint32_t tile=m[4]|((uint32_t)m[5]<<8);if(m[10]>4||m[11]>1||m[8]>31||m[9]>31||((m[10]==1||m[10]==4)&&(tile>=w->tile_type_count||tx_tile_framed(w,tile)||tx_tile_needs_section(tile)))){valid=0;break;}}
 close_world(handle);if(!valid)return bad("Invalid pixel palette or unsupported framed material; use a complete object companion");
 uint8_t* records=NULL;uint32_t rn=0;if(abc_region_read(bytes,n,(uint32_t)x,(uint32_t)y,width,height,&records,&rn))return -1;
 for(uint32_t px=0;px<width;px++)for(uint32_t py=0;py<height;py++){uint32_t index=indices[py*width+px];if(index>=map_count){free(records);return bad("Pixel index outside resolved palette");}if(!index)continue;const uint8_t* m=maps+index*12;uint32_t mode=m[10];if(mode==3)continue;
  uint32_t* r=(uint32_t*)records+(px*height+py)*8;
  if(mode==0){r[2]&=0xfffe0000u;r[3]=0;r[4]&=0xff00ffffu;}
  if(mode==1||mode==4){uint32_t flags=(r[2]>>16)|1u;flags=(flags&~4u)|((uint32_t)m[11]<<2);r[2]=(m[4]|((uint32_t)m[5]<<8))|(flags<<16);r[3]=0;r[4]=(r[4]&0xff00ffffu)|((uint32_t)m[8]<<16);}
  if(mode==2||mode==4){r[4]=(r[4]&0x00ff0000u)|(m[6]|((uint32_t)m[7]<<8))|((uint32_t)m[9]<<24);}
 }
 int result=abc_region_replace(bytes,n,(uint32_t)x,(uint32_t)y,width,height,records,rn,output,size);free(records);return result;
}
