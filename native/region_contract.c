/* Original synthetic fixture integration / sanitizer contract. */
#include "abc_region.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
int main(int argc,char**argv){
 assert(argc==2);FILE*f=fopen(argv[1],"rb");assert(f);fseek(f,0,SEEK_END);long len=ftell(f);rewind(f);uint8_t*b=malloc(len);assert(fread(b,1,len,f)==(size_t)len);fclose(f);
 uint8_t*r=NULL,*o=NULL,*candidate=NULL,*check=NULL;uint32_t rn=0,on=0,cn=0,checkn=0;
 assert(!abc_region_read(b,len,1,2,8,3,&r,&rn));assert(rn==768);
 assert(!abc_region_objects(b,len,1,2,8,3,&o,&on));assert(on>32);
 char request[512];snprintf(request,sizeof(request),"{\"x\":1,\"y\":10,\"width\":8,\"height\":3,\"recordCount\":24,\"recordSourceId\":2,\"mode\":\"overlay\",\"objectSourceId\":3,\"objectBytes\":%u,\"objectCount\":3}",on);
 assert(!abc_region_operation(b,len,"stamp_tiles",request,r,rn,o,on,&candidate,&cn));assert(candidate&&cn);
 assert(!abc_region_objects(candidate,cn,1,10,8,3,&check,&checkn));assert(checkn==on&&!memcmp(check+32,o+32,on-32));abc_region_free(check);abc_region_free(candidate);
 assert(abc_region_objects(b,len,2,2,1,2,&check,&checkn)!=0);assert(!check&&!checkn);
 ((uint32_t*)r)[4]|=3u<<16;assert(!abc_region_replace(b,len,1,2,8,3,r,rn,&candidate,&cn));assert(!abc_region_objects(candidate,cn,1,2,8,3,&check,&checkn));assert(checkn==on&&!memcmp(check,o,on));abc_region_free(check);abc_region_free(candidate);
 ((uint32_t*)r)[2]=0;assert(abc_region_replace(b,len,1,2,8,3,r,rn,&candidate,&cn)!=0);assert(!candidate&&!cn);
 uint8_t maps[24]={0};maps[10]=3;maps[16]=1;maps[22]=1;uint16_t pixels[4]={1,0,0,1};
 assert(abc_region_pixel(b,len,1,2,2,2,maps,2,pixels,&candidate,&cn)!=0);assert(!candidate&&!cn);
 assert(!abc_region_pixel(b,len,12,10,2,2,maps,2,pixels,&candidate,&cn));assert(candidate&&cn);abc_region_free(candidate);
 abc_region_free(r);abc_region_free(o);free(b);puts("Region object sanitizer contract passed");return 0;
}
