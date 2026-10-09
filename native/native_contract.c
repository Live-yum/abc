#include "abc_engine.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
static void check_at(int status,int line){ if(status){ char error[4096];uint32_t n=0;abc_error(error,sizeof error,&n);fprintf(stderr,"line=%d status=%d error=%s\n",line,status,error);abort();} }
#define check(s) check_at((s),__LINE__)
static uint8_t* readfile(const char* path,uint32_t* n){FILE* f=fopen(path,"rb");assert(f);fseek(f,0,SEEK_END);*n=(uint32_t)ftell(f);rewind(f);uint8_t* b=abc_alloc(*n);assert(b);assert(fread(b,1,*n,f)==*n);fclose(f);return b;}
static void operation(uint32_t h,const char* op,const char* json){uint32_t n=0;check(abc_world_operation(h,op,json,NULL,0,&n));assert(n>1);char* b=abc_alloc(n);check(abc_world_operation(h,op,json,b,n,&n));assert(b[n-1]==0);abc_free(b);}
static void hash_contract(void){
 const char* expected[]={"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"};
 uint8_t* allocation=abc_alloc(40);assert(allocation&&(uintptr_t)allocation>UINT32_MAX);
 uint32_t* out=(uint32_t*)allocation;uint8_t* input=allocation+4;uint8_t* digest=allocation+8;
 memcpy(input,"abc",3);
 for(uint32_t length=0;length<=3;length+=3){
  check(abc_sha256_create(out));uint32_t handle=*out;assert(handle);
  check(abc_sha256_update(handle,NULL,0));
  for(uint32_t at=0;at<length;at++)check(abc_sha256_update(handle,input+at,1));
  check(abc_sha256_final(handle,digest));char hex[65];
  for(uint32_t at=0;at<32;at++)snprintf(hex+at*2,3,"%02x",digest[at]);
  assert(!strcmp(hex,expected[length?1:0]));
  check(abc_sha256_final(handle,digest));assert(abc_sha256_update(handle,input,1)!=0);
  check(abc_sha256_destroy(handle));assert(abc_sha256_destroy(handle)!=0);
 }
 uint32_t handles[4];
 for(uint32_t i=0;i<4;i++){check(abc_sha256_create(out));handles[i]=*out;}
 assert(abc_sha256_create(out)!=0&&*out==0);
 for(uint32_t i=0;i<4;i++)check(abc_sha256_destroy(handles[i]));
 abc_free(allocation);
}
int main(int argc,char** argv){
 assert(argc==3);uint32_t wn,pn,h,n,r,w,height;
 hash_contract();
 uint8_t* world=readfile(argv[1],&wn);uint8_t* player=readfile(argv[2],&pn);
 /* Optional semantic fixture: tests encoder/decoder self-consistency only.
  * Pass a real game .plr separately for external compatibility evidence. */
 if(strstr(argv[2], ".json")){
  char* json=abc_alloc((size_t)pn+1);memcpy(json,player,pn);json[pn]=0;
  check(abc_player_open_json(json,&h));abc_free(json);abc_free(player);
  check(abc_player_save(h,NULL,0,&pn));player=abc_alloc(pn);
  check(abc_player_save(h,player,pn,&pn));check(abc_player_close(h));
 }
 assert(sizeof(void*)==8 && (uintptr_t)world>UINT32_MAX && (uintptr_t)player>UINT32_MAX);
 for(int iteration=0;iteration<12;iteration++){
 check(abc_world_open(world,wn,&h));
 check(abc_world_section(h,"header",NULL,0,&n));char* json=abc_alloc(n);check(abc_world_section(h,"header",json,n,&n));assert(json[n-1]==0);abc_free(json);
 check(abc_world_save(h,NULL,0,&n));uint8_t* clean=abc_alloc(n);check(abc_world_save(h,clean,n,&n));assert(n==wn && !memcmp(clean,world,n));abc_free(clean);
 operation(h,"header_patch","{\"patch\":{\"spawnTileX\":3,\"spawnTileY\":15}}");
 operation(h,"batch_update_tiles","{\"rules\":[{\"where\":{\"type\":1},\"patch\":{\"type\":2},\"limit\":5}]}");
 operation(h,"render_preview_png","{\"width\":64}");
 check(abc_world_thumbnail(h,NULL,0,&n,&w,&height));assert(n>8&&w>0&&height>0);uint8_t* png=abc_alloc(n);check(abc_world_thumbnail(h,png,n,&n,&w,&height));assert(png[0]==137&&png[1]=='P'&&png[2]=='N'&&png[3]=='G');abc_free(png);
 operation(h,"render_lit_map","{}");
 check(abc_world_map(h,NULL,0,&n,&w,&height));assert(n>0);uint8_t* map=abc_alloc(n);check(abc_world_map(h,map,n,&n,&w,&height));abc_free(map);
 check(abc_world_save(h,NULL,0,&n));uint8_t* output=abc_alloc(n);check(abc_world_save(h,output,n,&n));check(abc_world_close(h));check(abc_world_open(output,n,&r));check(abc_world_close(r));abc_free(output);
 check(abc_player_open(player,pn,&h));check(abc_player_save(h,NULL,0,&n));clean=abc_alloc(n);check(abc_player_save(h,clean,n,&n));assert(n==pn&&!memcmp(clean,player,n));abc_free(clean);
 check(abc_player_json(h,NULL,0,&n));json=abc_alloc(n);check(abc_player_json(h,json,n,&n));assert(json[n-1]==0);abc_free(json);
 check(abc_player_set(h,"/name","\"ABC native proof\""));check(abc_player_save(h,NULL,0,&n));output=abc_alloc(n);check(abc_player_save(h,output,n,&n));check(abc_player_close(h));check(abc_player_open(output,n,&r));check(abc_player_json(r,NULL,0,&n));json=abc_alloc(n);check(abc_player_json(r,json,n,&n));assert(strstr(json,"ABC native proof"));abc_free(json);check(abc_player_close(r));abc_free(output);
 }
 abc_free(world);abc_free(player);puts("PASS: high-address streaming SHA-256, WLD/PLR clean round-trip, JSON sizing, WLD metadata/tile edits, PNG/MAP render, edited export/reopen x12");return 0;
}
