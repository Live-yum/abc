/* Original test-only independent decoder proof. Not linked into the app ABI.
 * Uses the separately supplied engine's typed C reader, never Wasm32 pointers.
 * Invocation: stamp_readback original.wld stamped.wld
 */
#include "terra_world.h"
#include "terra_types.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern TxWorld* tx_get_world(uint32_t handle);
extern int read_tile_at(TxWorld*,uint32_t*,uint32_t,TxTile*);
static uint8_t* load(const char* path,uint32_t* size){
 FILE* f=fopen(path,"rb");assert(f);assert(!fseek(f,0,SEEK_END));long n=ftell(f);assert(n>0&&n<67108864);rewind(f);
 uint8_t* bytes=malloc((size_t)n);assert(bytes);assert(fread(bytes,1,(size_t)n,f)==(size_t)n);fclose(f);*size=(uint32_t)n;return bytes;
}
static TxTile* decode(TxWorld* w){
 assert(w->maxTilesX==7&&w->maxTilesY==32);
 TxTile* result=calloc(224,sizeof(TxTile));assert(result);uint32_t cursor=w->starts[1];
 for(uint32_t x=0;x<7;x++)for(uint32_t y=0;y<32;){
  TxTile tile;assert(read_tile_at(w,&cursor,w->ends[1],&tile));uint32_t n=(uint32_t)tile.same+1;assert(y+n<=32);tile.same=0;
  for(uint32_t k=0;k<n;k++){result[(y+k)*7+x]=tile;}
  y+=n;
 }
 assert(cursor==w->ends[1]);return result;
}
int main(int argc,char**argv){
 assert(argc==3);uint32_t an,bn,ah,bh;uint8_t*a=load(argv[1],&an),*b=load(argv[2],&bn);
 assert(!terra_world_open_from_buffer(a,an,&ah));TxWorld* aw=tx_get_world(ah);assert(aw);TxTile* before=decode(aw);
 uint32_t sectionCount=aw->pointer_count;uint32_t starts[16],ends[16];memcpy(starts,aw->starts,sizeof starts);memcpy(ends,aw->ends,sizeof ends);
 assert(!terra_world_close(ah));assert(!terra_world_open_from_buffer(b,bn,&bh));TxWorld*bw=tx_get_world(bh);assert(bw);TxTile*after=decode(bw);
 assert(sectionCount==bw->pointer_count);
 for(uint32_t s=0;s<sectionCount;s++){if(s==1)continue;assert(ends[s]-starts[s]==bw->ends[s]-bw->starts[s]);assert(!memcmp(a+starts[s],b+bw->starts[s],ends[s]-starts[s]));}
 before[10*7+2].active=1;before[10*7+2].type=0;before[10*7+2].tile_color=3;
 before[11*7+2].wall=1;before[11*7+2].wall_color=4;
 before[11*7+3].active=0;before[11*7+3].type=0;before[11*7+3].frame_x=0;before[11*7+3].frame_y=0;
 for(uint32_t i=0;i<224;i++){if(memcmp(before+i,after+i,sizeof(TxTile))){fprintf(stderr,"Mismatch at %u,%u\n",i%7,i/7);abort();}}
 assert(!terra_world_close(bh));free(a);free(b);free(before);free(after);
 puts("PASS: engine independently decoded every stamped and untouched tile; all non-tile sections byte-identical");return 0;
}
