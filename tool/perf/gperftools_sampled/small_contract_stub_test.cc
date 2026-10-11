/* OFFLINE ONLY. Linker-injected synthetic identities and public API provider.
 * This never links/loads libtcmalloc and never establishes official matches. */
#include <cassert>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <gperftools/malloc_extension.h>

namespace {
const char *scenario;
unsigned sample_calls, instance_calls, ownership_calls, known_allocations, known_frees;
unsigned probe_allocations, probe_frees, maps_opens, maps_reads, write_calls, close_calls;
unsigned known_live_at_sample[3];
int live_fds, maps_fd=-1, maps_index, maps_read_index;
size_t maps_offset;
void *known_pointer, *probe_pointer;
unsigned char tracked[4096], kinds[4096];
bool is(const char *value) { return !strcmp(scenario,value); }
int acquire(int fd,unsigned kind=0) {
  if(fd>=0) { assert(fd<4096 && !tracked[fd]); tracked[fd]=1; kinds[fd]=kind; ++live_fds; }
  return fd;
}
const char fixture[]=
  "heap profile:      1:      64 [     1:      64] @ heap_v2/524288\n"
  "     1:       64 [     1:       64] @ 0x1001\n\nMAPPED_LIBRARIES:\n"
  "00001000-00002000 r-xp 00000000 00:00 1 /offline/synthetic-provider\n";
class StubProvider final : public MallocExtension {
 public:
  void GetHeapSample(std::string *writer) override {
    assert(writer && writer->empty() && sample_calls<3);
    known_live_at_sample[sample_calls]=known_pointer!=nullptr;
    ++sample_calls;
    if(is("sample-throw-held") && sample_calls==2) throw std::runtime_error("synthetic");
    if(is("sample-empty")) return;
    if(is("sample-at-limit")) { writer->assign(1048576,'x'); return; }
    if(is("sample-nul")) { writer->assign(fixture); writer->push_back('\0'); return; }
    writer->append(fixture);
  }
  Ownership GetOwnership(const void *value) override {
    ++ownership_calls;
    if(value==known_pointer && known_pointer) {
      if(is("ownership-throw-known")) throw std::runtime_error("synthetic");
      if(is("ownership-bad-alloc-known")) throw std::bad_alloc();
      if(is("ownership-not-owned")) return kNotOwned;
    }
    if(value==probe_pointer && probe_pointer && is("probe-not-owned")) return kNotOwned;
    return value==known_pointer || value==probe_pointer ? kOwned : kNotOwned;
  }
} stub_provider, alternate_provider;
}
MallocExtension *MallocExtension::instance() {
  ++instance_calls;
  if(is("null-provider") || (is("null-provider-held") && known_pointer)) return nullptr;
  if(is("instance-throw-held") && known_pointer) throw std::runtime_error("synthetic");
  if(is("instance-changed-held") && known_pointer) return &alternate_provider;
  if(is("instance-changed-after-sample") && sample_calls) return &alternate_provider;
  return &stub_provider;
}

#define main small_contract_main
#include "small_sample_contract.cc"
#undef main

extern "C" void *__real_malloc(size_t);
extern "C" void __real_free(void *);
extern "C" int __real_open(const char *,int,...);
extern "C" int __real_openat(int,const char *,int,...);
extern "C" ssize_t __real_read(int,void *,size_t);
extern "C" ssize_t __real___read_chk(int,void *,size_t,size_t);
extern "C" ssize_t __read_chk(int,void *,size_t,size_t);
extern "C" ssize_t __real_write(int,const void *,size_t);
extern "C" int __real_close(int);
extern "C" int __real_fsync(int);

extern "C" void *__wrap_malloc(size_t bytes) {
  if(bytes==32u*1024u*1024u) {
    ++known_allocations;
    if(is("known-allocation-failure")) return nullptr;
    known_pointer=__real_malloc(bytes); return known_pointer;
  }
  if(bytes==1) {
    ++probe_allocations;
    if(is("probe-allocation-failure")) return nullptr;
    probe_pointer=__real_malloc(bytes); return probe_pointer;
  }
  return __real_malloc(bytes);
}
extern "C" void __wrap_free(void *value) {
  if(value && value==known_pointer) { ++known_frees; known_pointer=nullptr; }
  if(value && value==probe_pointer) { ++probe_frees; probe_pointer=nullptr; }
  __real_free(value);
}
extern "C" void *__wrap_dlsym(void *handle,const char *name) {
  assert(handle==RTLD_DEFAULT);
  if(!strcmp(name,"malloc")) return reinterpret_cast<void *>(&__real_malloc);
  if(!strcmp(name,"calloc")) return reinterpret_cast<void *>(&calloc);
  if(!strcmp(name,"realloc")) return reinterpret_cast<void *>(&realloc);
  if(!strcmp(name,"free")) return reinterpret_cast<void *>(&__real_free);
  assert(false); return nullptr;
}
extern "C" int __wrap_dladdr(const void *address,Dl_info *info) {
  bool wrong=(is("wrong-instance-address") && address==reinterpret_cast<void *>(&MallocExtension::instance)) ||
    (is("wrong-calloc-address") && address==reinterpret_cast<void *>(&calloc)) ||
    (is("wrong-realloc-address") && address==reinterpret_cast<void *>(&realloc)) ||
    (is("wrong-free-address") && address==reinterpret_cast<void *>(&__real_free)) ||
    (is("provider-address-changed") && sample_calls>0);
  *info={}; info->dli_fname=wrong?"/offline/wrong-provider":abc_sample_library.path;
  info->dli_fbase=reinterpret_cast<void *>(0x1000);
  return 1;
}
extern "C" int __wrap_open(const char *path,int flags,...) {
  mode_t mode=0;
  if(flags&O_CREAT) { va_list args;va_start(args,flags);mode=static_cast<mode_t>(va_arg(args,int));va_end(args); }
  if(!strcmp(path,"/proc/self/maps")) {
    ++maps_opens;maps_index=static_cast<int>(maps_opens);maps_offset=0;maps_read_index=0;
    if(is("maps-open-failure") && maps_index==1) {errno=EACCES;return -1;}
    maps_fd=acquire(__real_open("/dev/null",O_RDONLY|O_CLOEXEC),6);return maps_fd;
  }
  const unsigned kind=(flags&O_DIRECTORY)?7:
    (!strcmp(path,abc_sample_library.path) && library_fd<0)?8:0;
  return acquire(__real_open(path,flags,mode),kind);
}
extern "C" int __wrap_openat(int directory,const char *path,int flags,...) {
  mode_t mode=0;
  if(flags&O_CREAT) {va_list args;va_start(args,flags);mode=static_cast<mode_t>(va_arg(args,int));va_end(args);}
  unsigned kind=!strcmp(path,"before.maps")?1:!strcmp(path,"after.maps")?2:
    !strcmp(path,"capture.json")?3:!strcmp(path,ABC_SAMPLE_PENDING_NAME)?4:5;
  if(is("before-output-open-failure") && kind==1) {errno=EACCES;return -1;}
  if(is("before-symlink") && kind==1) assert(symlinkat("../untouched",directory,path)==0);
  return acquire(__real_openat(directory,path,flags,mode),kind);
}
extern "C" ssize_t __wrap_read(int fd,void *buffer,size_t count) {
  if(fd!=maps_fd) return __real_read(fd,buffer,count);
  ++maps_reads;++maps_read_index;
  if(maps_index==1 && (is("maps-read-error") || is("maps-read-eintr")) && maps_read_index==2) {
    errno=is("maps-read-eintr")?EINTR:EIO;return -1;
  }
  size_t size=32;
  if(maps_index==1 && is("maps-empty")) size=0;
  if(is("maps-at-limit") || (maps_index==1 && is("maps-over-limit"))) size=1048576;
  if(maps_index==1 && is("maps-over-limit")) ++size;
  if(maps_offset>=size) return 0;
  size_t n=size-maps_offset;
  if(n>count) n=count;
  memset(buffer,'x',n);
  if(n && maps_offset+n==size && !(maps_index==1 && is("maps-no-newline"))) static_cast<char *>(buffer)[n-1]='\n';
  maps_offset+=n;return static_cast<ssize_t>(n);
}
extern "C" ssize_t __wrap___read_chk(int fd,void *buffer,size_t count,size_t object_size) {
  // Preserve libc's actual fortified failure, including for synthetic maps.
  // Every non-maps descriptor continues through libc's checked read too.
  if(count>object_size || fd!=maps_fd || is("bypass-fortified-maps"))
    return __real___read_chk(fd,buffer,count,object_size);
  return __wrap_read(fd,buffer,count);
}
extern "C" ssize_t __wrap_write(int fd,const void *bytes,size_t count) {
  ++write_calls;
  if(kinds[fd]==1 && is("before-short-write")) return __real_write(fd,bytes,count/2);
  if(kinds[fd]==1 && is("before-write-eintr")) {errno=EINTR;return -1;}
  if(kinds[fd]==3 && (is("report-write-failure") || is("primary-and-report-failure"))) {errno=ENOSPC;return -1;}
  return __real_write(fd,bytes,count);
}
extern "C" int __wrap_fsync(int fd) {
  if(kinds[fd]==1 && is("before-sync-failure")) {errno=EIO;return -1;}
  return __real_fsync(fd);
}
extern "C" int __wrap_close(int fd) {
  assert(fd>=0 && fd<4096 && tracked[fd]);
  unsigned kind=kinds[fd];tracked[fd]=0;kinds[fd]=0;--live_fds;++close_calls;
  if(fd==maps_fd) maps_fd=-1;
  const bool fail=(kind==6 && is("maps-close-failure") && maps_index==1) ||
    (kind==1 && is("before-close-failure")) || (kind==7 && is("root-close-failure")) ||
    (kind==8 && is("library-close-failure"));
  int result=__real_close(fd);
  if(fail) {errno=EINTR;return -1;}
  return result;
}

int main(int argc,char **argv) {
  if(argc==2 && !strcmp(argv[1],"--offline-build-info")) {
    printf("{\"offline\":true,\"officialRuntimeInvoked\":false,\"fortifyLevel\":%d}\n",__USE_FORTIFY_LEVEL);
    return 0;
  }
  if(argc!=3 && argc!=4) return 2;
  scenario=argv[1];
  if(is("fortified-read-boundary")) {
    if(argc!=4) return 2;
    // Runtime count prevents the compiler diagnosing the intentional negative
    // test before libc's actual buffer-overflow guard can be exercised.
    char byte[1];
    const size_t count=static_cast<size_t>(strtoul(argv[3],nullptr,10));
    const int fd=open("/proc/self/maps",O_RDONLY|O_CLOEXEC);
    if(fd<0) return 3;
    const ssize_t n=__read_chk(fd,byte,count,sizeof byte);
    close(fd);
    printf("{\"offline\":true,\"officialRuntimeInvoked\":false,\"fortifiedReadBytes\":%zd}\n",n);
    return 0;
  }
  if(is("primary-and-report-failure")) assert(setenv("TCMALLOC_SAMPLE_PARAMETER","bad",1)==0);
  char *args[]={argv[0],argv[2],nullptr};
  int result=small_contract_main(2,args);
  printf("{\"offline\":true,\"officialRuntimeInvoked\":false,\"exitStatus\":%d,"
    "\"fortifyLevel\":%d,"
    "\"sampleCalls\":%u,\"instanceCalls\":%u,\"ownershipCalls\":%u,"
    "\"knownAllocations\":%u,\"knownFrees\":%u,\"probeAllocations\":%u,\"probeFrees\":%u,"
    "\"knownLiveAtSample\":[%u,%u,%u],\"knownStillLive\":%d,\"probeStillLive\":%d,"
    "\"mapsOpens\":%u,\"mapsReads\":%u,\"writeCalls\":%u,\"closeCalls\":%u,\"liveFds\":%d}\n",
    result,__USE_FORTIFY_LEVEL,sample_calls,instance_calls,ownership_calls,known_allocations,known_frees,
    probe_allocations,probe_frees,known_live_at_sample[0],known_live_at_sample[1],known_live_at_sample[2],
    known_pointer!=nullptr,probe_pointer!=nullptr,maps_opens,maps_reads,write_calls,close_calls,live_fds);
  return 0;
}
