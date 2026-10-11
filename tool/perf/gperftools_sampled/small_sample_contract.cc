/* Official-API small contract, executed only by the separately approved CI.
 * Three fixed snapshots around one allocation/free. No full-profiler calls. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "sample_wrapper.h"
#include <gperftools/malloc_extension.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <new>
#include <memory>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include "native_identity.h"
#pragma GCC diagnostic pop
#ifndef ABC_SAMPLE_LIBRARY_CONFIG
#error "Supply the fixed official library identity header"
#endif
#include ABC_SAMPLE_LIBRARY_CONFIG

static char maps_buffer[1048576];
static void *provider_base;
static void *provider_symbols[5];
static MallocExtension *provider;
static void *owned_probe;
static int root_fd = -1;
static int library_fd = -1;
static int cleanup_errno;
static const size_t known_bytes = 32u * 1024u * 1024u;

extern "C" __attribute__((noinline)) void *abc_sample_known_allocate(size_t bytes) {
  void *value = malloc(bytes);
  asm volatile("" : "+r"(value) :: "memory");
  return value;
}

static int close_once(int fd) {
  const int result=close(fd);
  if(result && !cleanup_errno) cleanup_errno=errno?errno:EIO;
  return result;
}

static int write_once(int directory, const char *name, const char *bytes, size_t length) {
  if(length>sizeof maps_buffer) return -1;
  int fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0) return -1;
  struct stat st;
  int valid=!fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_uid==geteuid() &&
            (st.st_mode&07777)==0600 && st.st_nlink==1 && st.st_size==0;
  ssize_t written=valid?write(fd,bytes,length):-1;
  int synced=written==(ssize_t)length && !fstat(fd,&st) &&
             S_ISREG(st.st_mode) && st.st_nlink==1 && st.st_size==(off_t)length ? fsync(fd) : -1;
  int closed=close_once(fd);
  return written==(ssize_t)length && synced==0 && closed==0 ? 0 : -1;
}

static int save_maps(int directory,const char *name) {
  int fd=open("/proc/self/maps",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
  if(fd<0) return -1;
  size_t used=0;int error=0;
  while(used<sizeof maps_buffer) {
    ssize_t n=read(fd,maps_buffer+used,sizeof maps_buffer-used);
    if(n<0) {error=1;break;}
    if(!n) break;
    used+=(size_t)n;
  }
  char extra;ssize_t overflow=error?-1:read(fd,&extra,1);
  int closed=close_once(fd);
  // Preserve all bounded bytes even when the complete-read checks fail.
  int saved=write_once(directory,name,maps_buffer,used);
  return !error && !overflow && !closed && !saved && used && maps_buffer[used-1]=='\n' ? 0 : -1;
}

static void *current_symbol(unsigned index) {
  const char *names[]={"malloc","calloc","realloc","free"};
  if(index<4) return dlsym(RTLD_DEFAULT,names[index]);
  // Compiler-resolved PUBLIC method; no guessed mangled or virtual symbols.
  return reinterpret_cast<void *>(&MallocExtension::instance);
}

static int provider_matches(void *) {
  int checked=abc_open_identity(&abc_sample_library,0);
  if(checked<0) return 0;
  int closed=close_once(checked);
  if(closed) return 0;
  struct stat st;
  if(fstat(library_fd,&st) || (uint64_t)st.st_dev!=abc_sample_library.device ||
     (uint64_t)st.st_ino!=abc_sample_library.inode ||
     (uint64_t)st.st_size!=abc_sample_library.size || !S_ISREG(st.st_mode)) return 0;
  for(unsigned i=0;i<5;i++) {
    void *symbol=current_symbol(i);Dl_info info={};
    if(!symbol || symbol!=provider_symbols[i] || !dladdr(symbol,&info) ||
       info.dli_fbase!=provider_base || !info.dli_fname ||
       strcmp(info.dli_fname,abc_sample_library.path)) return 0;
  }
  MallocExtension *current=MallocExtension::instance();
  return current && current==provider && owned_probe &&
         current->GetOwnership(owned_probe)==MallocExtension::kOwned;
}

static int capture(const char *name) {
  if(mkdirat(root_fd,name,0700)) return 20;
  int directory=openat(root_fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(directory<0) return 21;
  struct stat st={};
  int status=0;
  if(fstat(directory,&st)) status=22;
  abc_sample_context context={};
  abc_sample_config config={ABC_SAMPLE_ABI,directory,(uint64_t)st.st_dev,
                           (uint64_t)st.st_ino,nullptr,provider_matches};
  if(!status && abc_sample_initialize(&context,&config)) status=23;
  if(!status && save_maps(directory,"before.maps")) status=24;
  if(!status && abc_sample_capture_q0(&context,0)) status=25;
  // Preserve the after map even after a capture failure, once, not a retry.
  if(save_maps(directory,"after.maps") && !status) status=26;
  char report[2048];
  const abc_sample_result &r=context.result;
  int bytes=snprintf(report,sizeof report,
      "{\"schema\":\"abc.official-sampled-small-cut.v1\",\"pid\":%ld,\"status\":%d,"
      "\"nativeStatus\":%d,\"transportAccepted\":%d,\"apiCalls\":%u,"
      "\"apiStartNs\":%llu,\"apiEndNs\":%llu,\"returnedBytes\":%llu,"
      "\"writtenBytes\":%llu,\"published\":%d,\"cleanupErrno\":%d}\n",
      (long)getpid(),status,r.status,r.accepted,r.api_calls,
      (unsigned long long)r.api_start_ns,(unsigned long long)r.api_end_ns,
      (unsigned long long)r.returned_bytes,(unsigned long long)r.written_bytes,r.published,r.cleanup_errno);
  if(bytes<=0 || bytes>=(int)sizeof report || write_once(directory,"capture.json",report,(size_t)bytes)) {
    if(!status) status=27;
  }
  if(close_once(directory) && !status) status=28;
  return status;
}

static int run_contract(const char *output) {
#ifndef ABC_SAMPLE_OFFLINE_TESTING
  if(strcmp(abc_sample_library.path,"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16")) return 5;
#endif
  if(!abc_canonical(output)) return 2;
  root_fd=open(output,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(root_fd<0) return 3;
  struct stat root;
  if(fstat(root_fd,&root) || !S_ISDIR(root.st_mode) || root.st_uid!=geteuid() || (root.st_mode&07777)!=0700) return 4;
  library_fd=abc_open_identity(&abc_sample_library,0);
  if(library_fd<0) return 5;
  for(unsigned i=0;i<5;i++) {
    provider_symbols[i]=current_symbol(i);
    Dl_info info={};
    if(!provider_symbols[i] || !dladdr(provider_symbols[i],&info) || !info.dli_fname ||
       strcmp(info.dli_fname,abc_sample_library.path) ||
       (i && info.dli_fbase!=provider_base)) return 6;
    if(!i) provider_base=info.dli_fbase;
  }
  provider=MallocExtension::instance();
  if(!provider) return 7;
  owned_probe=malloc(1);
  if(!owned_probe) return 7;
  if(!provider_matches(nullptr)) return 7;
  int status=capture("baseline");if(status) return status;
  std::unique_ptr<void,decltype(&free)> known(abc_sample_known_allocate(known_bytes),&free);
  if(!known) return 8;
  memset(known.get(),0x5a,known_bytes);
  MallocExtension *current=MallocExtension::instance();
  if(!current || current!=provider || current->GetOwnership(known.get())!=MallocExtension::kOwned) return 9;
  status=capture("held");
  known.reset();
  if(status) return status;
  return capture("freed");
}

int main(int argc,char **argv) {
  if(argc!=2) return 1;
  int status=0;
  try {status=run_contract(argv[1]);} catch(const std::bad_alloc &) {status=90;} catch(...) {status=91;}
  if(owned_probe) {free(owned_probe);owned_probe=nullptr;}
  if(library_fd>=0) {int fd=library_fd;library_fd=-1;close_once(fd);}
  if(root_fd>=0) {int fd=root_fd;root_fd=-1;close_once(fd);}
  printf("{\"schema\":\"abc.official-sampled-small-execution.v1\",\"status\":%d,\"cleanupErrno\":%d,\"knownBytes\":%zu,\"samplePeriodBytes\":524288,\"snapshotsPlanned\":3,\"fullHeapCoverage\":false}\n",status,cleanup_errno,known_bytes);
  return status?status:(cleanup_errno?92:0);
}
