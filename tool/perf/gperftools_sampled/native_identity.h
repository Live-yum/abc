/* Local, bounded SHA-256 + fixed file identity checks. No external command. */
#ifndef ABC_NATIVE_IDENTITY_H
#define ABC_NATIVE_IDENTITY_H
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct abc_file_identity {
    const char *path;
    uint64_t device, inode, size;
    const char *sha256;
};
struct abc_arm_identity {
    const char *name, *output;
    uint64_t device, inode;
};
struct abc_sha { uint32_t h[8]; uint64_t size; unsigned used; unsigned char block[64]; };
static uint32_t abc_rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32-n)); }
static void abc_sha_block(struct abc_sha *s) {
    static const uint32_t k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    uint32_t w[64];
    for (unsigned i=0;i<16;i++) w[i]=((uint32_t)s->block[4*i]<<24)|((uint32_t)s->block[4*i+1]<<16)|((uint32_t)s->block[4*i+2]<<8)|s->block[4*i+3];
    for (unsigned i=16;i<64;i++) {
        uint32_t a=w[i-15], b=w[i-2];
        w[i]=w[i-16]+(abc_rotr(a,7)^abc_rotr(a,18)^(a>>3))+w[i-7]+(abc_rotr(b,17)^abc_rotr(b,19)^(b>>10));
    }
    uint32_t a=s->h[0],b=s->h[1],c=s->h[2],d=s->h[3],e=s->h[4],f=s->h[5],g=s->h[6],h=s->h[7];
    for (unsigned i=0;i<64;i++) {
        uint32_t t=h+(abc_rotr(e,6)^abc_rotr(e,11)^abc_rotr(e,25))+((e&f)^((~e)&g))+k[i]+w[i];
        uint32_t u=(abc_rotr(a,2)^abc_rotr(a,13)^abc_rotr(a,22))+((a&b)^(a&c)^(b&c));
        h=g;g=f;f=e;e=d+t;d=c;c=b;b=a;a=t+u;
    }
    s->h[0]+=a;s->h[1]+=b;s->h[2]+=c;s->h[3]+=d;s->h[4]+=e;s->h[5]+=f;s->h[6]+=g;s->h[7]+=h;
}
static void abc_sha_update(struct abc_sha *s, const unsigned char *p, size_t n) {
    s->size+=n;
    for(size_t i=0;i<n;i++) { s->block[s->used++]=p[i]; if(s->used==64) {abc_sha_block(s);s->used=0;} }
}
static int abc_sha_fd(int fd, char out[65]) {
    struct abc_sha s={{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19},0,0,{0}};
    unsigned char buf[8192]; ssize_t n;
    if(lseek(fd,0,SEEK_SET)<0) return -1;
    while((n=read(fd,buf,sizeof buf))!=0) {
        if(n<0) { if(errno==EINTR) continue; return -1; }
        if(s.size+(uint64_t)n>64u*1024u*1024u) return -1;
        abc_sha_update(&s,buf,(size_t)n);
    }
    uint64_t bits=s.size*8;
    buf[0]=0x80;abc_sha_update(&s,buf,1);
    buf[0]=0;
    while(s.used!=56) abc_sha_update(&s,buf,1);
    for(unsigned i=0;i<8;i++) buf[i]=(unsigned char)(bits>>(56-8*i));
    abc_sha_update(&s,buf,8);
    for(unsigned i=0;i<8;i++) (void)snprintf(out+8*i,9,"%08x",s.h[i]);
    return lseek(fd,0,SEEK_SET)<0?-1:0;
}
static int abc_canonical(const char *path) {
    char actual[PATH_MAX];
    return path && path[0]=='/' && realpath(path,actual) && !strcmp(path,actual);
}
/* Returns a retained fd. Caller owns it; failed checks never repair a path. */
static int abc_open_identity(const struct abc_file_identity *id, int executable) {
    struct stat before,after; char digest[65];
    if(!id || !id->sha256 || strlen(id->sha256)!=64 || !abc_canonical(id->path)) return -1;
    int fd=open(id->path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0) return -1;
    if(fstat(fd,&before) || !S_ISREG(before.st_mode) ||
       (executable && !(before.st_mode&0111)) ||
       (uint64_t)before.st_dev!=id->device || (uint64_t)before.st_ino!=id->inode ||
       (uint64_t)before.st_size!=id->size || id->size>64u*1024u*1024u ||
       abc_sha_fd(fd,digest) || strcmp(digest,id->sha256) || fstat(fd,&after) ||
       before.st_size!=after.st_size || before.st_mtim.tv_sec!=after.st_mtim.tv_sec ||
       before.st_mtim.tv_nsec!=after.st_mtim.tv_nsec || before.st_ctim.tv_sec!=after.st_ctim.tv_sec ||
       before.st_ctim.tv_nsec!=after.st_ctim.tv_nsec) { close(fd);return -1; }
    return fd;
}
static int abc_open_output(const struct abc_arm_identity *arm) {
    struct stat st;
    if(!arm || !abc_canonical(arm->output)) return -1;
    int fd=open(arm->output,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0) return -1;
    if(fstat(fd,&st) || !S_ISDIR(st.st_mode) || st.st_uid!=geteuid() ||
       (st.st_mode&0777)!=0700 || (uint64_t)st.st_dev!=arm->device ||
       (uint64_t)st.st_ino!=arm->inode) {close(fd);return -1;}
    return fd;
}
static int abc_profiler_variable(const char *entry) {
    return !strncmp(entry,"LD_",3) || !strncmp(entry,"HEAP",4) ||
           !strncmp(entry,"TCMALLOC",8) || !strncmp(entry,"CPUPROFILE",10) ||
           !strncmp(entry,"MALLOC",6) || !strncmp(entry,"ABC_STACK_OUTPUT=",17);
}
#endif
