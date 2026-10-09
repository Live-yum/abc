#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "abc_world_circuit.h"
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* REQUIRE deliberately remains active with -DNDEBUG: calls have side effects. */
#define REQUIRE(test) do { if (!(test)) { fprintf(stderr, "load-only check failed at line %d: %s\n", __LINE__, #test); exit(2); } } while (0)
#define CIRCUIT_ABI 2u
static FILE *sources[3];
static uint8_t *window;
static uint32_t circuit;
static double start, next_stats;
static uint64_t read_bytes[3], write_bytes[3];
static uint8_t *frame;
static const char *phase_names[] = {"unknown", "compile.topology", "compile.roots", "compile.number", "compile.remap", "compile.map_size", "compile.map_encode", "compile.count", "compile.layout", "compile.zero", "compile.write", "compile.flush", "compile.intern", "ready", "query", "run", "save.prefix", "save.tiles", "save.suffix", "save.patch", "failed", "cancelled", "ticks", "fragments"};
static double now(void) { struct timespec t; REQUIRE(!clock_gettime(CLOCK_MONOTONIC,&t)); return t.tv_sec+t.tv_nsec/1e9; }
static void check(int32_t s) { if(s<0) { char msg[4096]={0}; uint32_t n=0; abc_error(msg,sizeof(msg),&n); fprintf(stderr,"engine status %d: %s\n",s,msg); exit(2); } }
static uint32_t circuit_abi(void) {
  const char *build=abc_engine_build_info(); REQUIRE(build);
  const char *value=strstr(build,"\"circuitWorldAbiVersion\""); REQUIRE(value);
  value+=strlen("\"circuitWorldAbiVersion\"");
  while(isspace((unsigned char)*value)) value++;
  REQUIRE(*value++==':'); while(isspace((unsigned char)*value)) value++;
  REQUIRE(isdigit((unsigned char)*value)); char *end=NULL; errno=0;
  unsigned long version=strtoul(value,&end,10); REQUIRE(!errno && version<=UINT32_MAX);
  while(isspace((unsigned char)*end)) end++;
  REQUIRE(*end==',' || *end=='}'); return (uint32_t)version;
}
static void mark(const char *phase, uint32_t engine_phase, const char *detail) {
  struct rusage ru; REQUIRE(!getrusage(RUSAGE_SELF,&ru));
  uint32_t stats[24]={0}; if(circuit) { check(abc_world_circuit_stats(circuit,stats)); REQUIRE(stats[0]==CIRCUIT_ABI); }
  printf("{\"event\":\"phase\",\"phase\":\"%s\",\"elapsed_seconds\":%.9f,\"monotonic_seconds\":%.9f,\"engine_phase\":%u,\"ru_maxrss_bytes\":%llu,",phase,now()-start,now(),engine_phase,(unsigned long long)ru.ru_maxrss*1024);
  if(circuit) {
    printf("\"engine_active_bytes\":%u,\"engine_peak_bytes\":%u,\"stats\":[",stats[16],stats[17]);
    for(int i=0;i<24;i++) printf("%s%u",i?",":"",stats[i]);
    printf("]");
  } else printf("\"engine_active_bytes\":null,\"engine_peak_bytes\":null,\"stats\":null");
  printf(",\"detail\":\"%s\"}\n",detail?detail:""); fflush(stdout);
}
static uint32_t size(FILE *f) { struct stat st; REQUIRE(!fstat(fileno(f),&st)); REQUIRE(st.st_size>0 && st.st_size<UINT32_MAX); return (uint32_t)st.st_size; }
static void hash_file(FILE *f, const char *name, const char *expected) {
  EVP_MD_CTX *ctx=EVP_MD_CTX_new(); REQUIRE(ctx); REQUIRE(EVP_DigestInit_ex(ctx,EVP_sha256(),NULL));
  REQUIRE(!fseeko(f,0,SEEK_SET)); size_t n;
  while((n=fread(window,1,1024*1024,f))) REQUIRE(EVP_DigestUpdate(ctx,window,n));
  REQUIRE(!ferror(f)); uint8_t digest[32]; unsigned len=0; REQUIRE(EVP_DigestFinal_ex(ctx,digest,&len)); REQUIRE(len==32); EVP_MD_CTX_free(ctx);
  char hex[65]; for(int i=0;i<32;i++) sprintf(hex+i*2,"%02x",digest[i]); REQUIRE(!strcmp(hex,expected));
  printf("{\"event\":\"source_hash\",\"name\":\"%s\",\"sha256\":\"%s\",\"bytes\":%u,\"elapsed_seconds\":%.9f}\n",name,hex,size(f),now()-start); fflush(stdout);
}
static void read_source(uint32_t id,uint32_t off,uint32_t len) { REQUIRE(id<3 && sources[id] && len<=1024*1024); REQUIRE(!fseeko(sources[id],off,SEEK_SET)); REQUIRE(fread(window,1,len,sources[id])==len); read_bytes[id]+=len; }
static uint32_t last_phase=UINT32_MAX;
static void pump(uint8_t *records,uint32_t capacity,uint32_t *record_size,int loading) {
  uint32_t e[12]; const uint8_t *data=NULL;
  for(;;) {
    check(abc_world_circuit_step(circuit,4096,e,&data)); REQUIRE(e[0]==CIRCUIT_ABI && !e[5]);
    if(loading && e[6]!=last_phase) { last_phase=e[6]; mark(e[6]<sizeof(phase_names)/sizeof(phase_names[0])?phase_names[e[6]]:"unknown",e[6],"engine event boundary; just-completed step may have crossed phases"); }
    if(now()>=next_stats) { uint32_t s[24]; check(abc_world_circuit_stats(circuit,s)); REQUIRE(s[0]==CIRCUIT_ABI); printf("{\"event\":\"engine_sample\",\"elapsed_seconds\":%.9f,\"monotonic_seconds\":%.9f,\"engine_phase\":%u,\"engine_active_bytes\":%u,\"engine_peak_bytes\":%u}\n",now()-start,now(),s[15],s[16],s[17]); fflush(stdout); next_stats=now()+0.1; }
    if(e[1]==4) { if(records) REQUIRE(e[9]==9); break; }
    if(e[1]==1) { read_source(e[2],e[3],e[4]); check(abc_world_circuit_supply(circuit,e[2],e[3],window,e[4])); }
    else if(e[1]==2) { REQUIRE(e[2]==2 && data); REQUIRE(!fseeko(sources[2],e[3],SEEK_SET)); REQUIRE(fwrite(data,1,e[4],sources[2])==e[4]); write_bytes[2]+=e[4]; check(abc_world_circuit_ack(circuit)); }
    else if(e[1]==3) { REQUIRE(records && record_size && *record_size+e[4]<=capacity); memcpy(records+*record_size,data,e[4]); *record_size+=e[4]; check(abc_world_circuit_ack(circuit)); }
    else REQUIRE(e[1]==0);
  }
}
static void display(uint32_t x,uint32_t y,uint32_t w,uint32_t h) {
  uint32_t cmd[16]={CIRCUIT_ABI,9,x,y,w,h,1}, bytes=0, count=w*h;
  uint8_t *records=calloc(count,16), *seen=calloc(count,1); REQUIRE(records&&seen); frame=calloc(count,4); REQUIRE(frame);
  check(abc_world_circuit_command(circuit,cmd,NULL)); pump(records,count*16,&bytes,0); REQUIRE(bytes==count*16);
  for(uint32_t i=0;i<count;i++) {
    uint32_t a[4]; memcpy(a,records+i*16,16); uint32_t px=a[0]-x,py=a[1]-y,tile=a[2]&65535; int16_t fx=a[3]&65535,fy=a[3]>>16;
    REQUIRE(px<w&&py<h&&tile==445&&fx>=0&&fx<=18&&!(fx%18)&&fy==0);
    uint32_t at=py*w+px; REQUIRE(!seen[at]); seen[at]=1; uint32_t rgb=fx?0xffffff:0;
    frame[4*at]=rgb>>16; frame[4*at+1]=rgb>>8; frame[4*at+2]=rgb; frame[4*at+3]=255;
  }
  printf("{\"event\":\"display\",\"name\":\"mono\",\"x\":%u,\"y\":%u,\"width\":%u,\"height\":%u,\"records\":%u,\"rgba_bytes\":%u}\n",x,y,w,h,count,count*4); fflush(stdout); free(seen); free(records);
}
int main(int argc,char **argv) {
  REQUIRE(argc==4); setvbuf(stdout,NULL,_IOLBF,0); start=now();
  /* Verify that the sampler hashes the library actually bound to this host. */
  Dl_info info; struct stat expected, actual;
  REQUIRE(dladdr(dlsym(RTLD_DEFAULT,"abc_engine_abi_version"),&info) && info.dli_fname);
  REQUIRE(!stat(argv[3],&expected) && !stat(info.dli_fname,&actual));
  REQUIRE(expected.st_dev==actual.st_dev && expected.st_ino==actual.st_ino);
  uint32_t version=circuit_abi(); REQUIRE(version==CIRCUIT_ABI);
  printf("{\"event\":\"identity\",\"pid\":%d,\"runtime\":\"standalone C host; streamed Native C engine; no Dart/Flutter/browser\",\"load_scope\":\"wld-only-mono64x48\",\"engine_budget_bytes\":201326592,\"engine_abi_version\":%u,\"circuit_world_abi_version\":%u}\n",getpid(),abc_engine_abi_version(),version);
  mark("baseline",0,"shared libraries already loaded; no sources or host input window allocated");
  struct timespec pause={0,50000000}; nanosleep(&pause,NULL);
  sources[1]=fopen(argv[1],"rb"); sources[2]=fopen(argv[2],"w+bx"); REQUIRE(sources[1]&&sources[2]);
  window=malloc(1024*1024); REQUIRE(window); mark("source_hash",0,NULL);
  hash_file(sources[1],"computerraria.wld","55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33");
  mark("open_parse",0,NULL); uint32_t task=0,world=0,e[12]; const uint8_t *data=NULL;
  check(abc_world_stream_open_begin(1,size(sources[1]),&task));
  for(;;) { check(abc_world_stream_step(task,4096,e,&data)); REQUIRE(e[0]==1 && !e[5]); if(e[1]==4) break; if(e[1]==1) { read_source(e[2],e[3],e[4]); check(abc_world_stream_supply(task,e[2],e[3],window,e[4])); } else REQUIRE(e[1]==0); }
  check(abc_world_stream_adopt(task,1,&world)); check(abc_world_stream_close(task));
  mark("circuit_begin",0,NULL); check(abc_world_circuit_begin(world,2,192*1024*1024,&circuit));
  pump(NULL,0,NULL,1); mark("circuit_loaded",13,"complete WLD circuit import ready; no clock pulses");
  uint32_t stats[24]; check(abc_world_circuit_stats(circuit,stats)); REQUIRE(stats[0]==CIRCUIT_ABI && stats[2]==15200 && stats[3]==7200 && stats[14]==15200 && stats[18]==0 && stats[20]==0);
  mark("display_init",13,"read physical mono pixel records; validate and decode RGBA in C; no raster rendering");
  display(6485,800,64,48);
  mark("loaded",13,"mono64x48 initialized; no CPU/Pong/run/export"); nanosleep(&pause,NULL);
  mark("close",13,NULL); check(abc_world_circuit_close(circuit)); circuit=0; check(abc_world_close(world));
  for(int i=0;i<3;i++) { if(sources[i]) fclose(sources[i]); }
  free(frame); free(window);
  mark("closed",0,"engine/world/input/frames released; libc may retain freed pages"); nanosleep(&pause,NULL);
  printf("{\"event\":\"io\",\"world_read_bytes\":%" PRIu64 ",\"scratch_read_bytes\":%" PRIu64 ",\"scratch_write_bytes\":%" PRIu64 "}\n",read_bytes[1],read_bytes[2],write_bytes[2]);
  return 0;
}
