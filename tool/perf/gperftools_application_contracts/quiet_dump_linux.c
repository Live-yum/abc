/* Linux adapter. This is compiled by offline tests, but never loaded with a
 * real profiler by them. No constructor, Start, GetHeapProfile, or exit dump. */
#define _GNU_SOURCE
#include "quiet_dump_bridge.h"
#include "native_identity.h"
#ifndef ABC_SEALED_CONFIG
#error "Pass the same sealed config header used for target_launcher.c"
#endif
#include ABC_SEALED_CONFIG
#include <dlfcn.h>
#include <inttypes.h>
#include <sys/syscall.h>
#include <time.h>

static struct abc_quiet_context context;
static const char *const symbol_names[]={"malloc","calloc","realloc","free","HeapProfilerDump","HeapProfilerStop","IsHeapProfilerRunning"};
static struct {
    const struct abc_arm_identity *arm;
    int output, target, library;
    int init_attempted;
    void *symbols[7],*base;
    void (*dump)(const char *);
    void (*stop)(void);
    int (*running)(void);
} runtime={.output=-1,.target=-1,.library=-1};

static void release_runtime_files(void) {
    int *fds[]={&runtime.target,&runtime.library,&runtime.output};
    for(unsigned i=0;i<3;i++) if(*fds[i]>=0) {
        int fd=*fds[i];*fds[i]=-1; /* Never close a possibly reused number twice. */
        ++context.meta.observer_fd_close_attempts;
        if(close(fd)) context.meta.observer_fd_cleanup_failure=errno?errno:EIO;
        else ++context.meta.observer_closed_fds;
        if(context.meta.observer_held_fds) --context.meta.observer_held_fds;
    }
}
static int open_runtime_files(void) {
    runtime.target=abc_open_identity(&abc_sealed_target,1);
    if(runtime.target<0) return ABC_QUIET_BAD_INIT;
    ++context.meta.observer_held_fds;
    runtime.library=abc_open_identity(&abc_sealed_library,0);
    if(runtime.library<0) return ABC_QUIET_BAD_INIT;
    ++context.meta.observer_held_fds;
    runtime.output=abc_open_output(runtime.arm);
    if(runtime.output<0) return ABC_QUIET_BAD_INIT;
    ++context.meta.observer_held_fds;
    return ABC_QUIET_OK;
}
static int initialization_failed(int status) {
    if(!context.meta.failure) context.meta.failure=status;
    context.meta.abi=ABC_QUIET_ABI;
    release_runtime_files();
    return status;
}

static uint64_t clock_ns(void *unused) {
    (void)unused;struct timespec t;
    if(clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static int provider_matches(void *unused) {
    (void)unused;
    int fd=abc_open_identity(&abc_sealed_library,0);
    if(fd<0) return 0;
    close(fd);
    for(unsigned i=0;i<7;i++) {
        Dl_info info;void *symbol=dlsym(RTLD_DEFAULT,symbol_names[i]);
        if(!symbol || symbol!=runtime.symbols[i] || !dladdr(symbol,&info) ||
           info.dli_fbase!=runtime.base || !info.dli_fname || strcmp(info.dli_fname,abc_sealed_library.path)) return 0;
    }
    int output=abc_open_output(runtime.arm);
    if(output<0) return 0;
    close(output);return 1;
}
static int running(void *unused) {(void)unused;return runtime.running();}
static void dump(void *unused,const char *reason) {(void)unused;runtime.dump(reason);}
static void stop(void *unused) {(void)unused;runtime.stop();release_runtime_files();}
static int map_read(void *unused,char *buffer,size_t cap,size_t *length) {
    (void)unused;*length=0;
    int fd=open("/proc/self/maps",O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0) return -1;
    while(*length<cap) {
        ssize_t n=read(fd,buffer+*length,cap-*length);
        if(n<0 && errno==EINTR) continue;
        if(n<0) {close(fd);return -1;}
        if(!n) break;
        *length+=(size_t)n;
    }
    char extra;ssize_t n;
    do {n=read(fd,&extra,1);} while(n<0 && errno==EINTR);
    int closed=close(fd);
    return n || closed || !*length || buffer[*length-1]!='\n'?-1:0;
}
static int write_new(const char *name,const char *data,size_t size) {
    int fd=openat(runtime.output,name,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
    if(fd<0) return -1;
    size_t done=0;
    while(done<size) {
        ssize_t n=write(fd,data+done,size-done);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) {close(fd);return -1;}
        done+=(size_t)n;
    }
    int synced=fsync(fd),closed=close(fd);
    return synced || closed?-1:0;
}
static int publish(void *unused,unsigned slot,const struct abc_quiet_cut *cut,const char *before,const char *after) {
    (void)unused;char name[64],pending[64],receipt[ABC_RECEIPT_CAP];
    int cycle=slot?7:0;
    (void)snprintf(name,sizeof name,"q%d.before.maps",cycle);
    if(write_new(name,before,cut->maps_before_size)) return -1;
    (void)snprintf(name,sizeof name,"q%d.after.maps",cycle);
    if(write_new(name,after,cut->maps_after_size)) return -1;
    int size=snprintf(receipt,sizeof receipt,"ABC_HEAP_RECEIPT_V1 %u %d %ld %" PRIu64 " %" PRIu64 " %zu %zu heap.%04u.heap\n",slot,cycle,(long)getpid(),cut->dump_start_ns,cut->dump_end_ns,cut->maps_before_size,cut->maps_after_size,slot+1);
    if(size<=0 || size>=(int)sizeof receipt) return -1;
    (void)snprintf(pending,sizeof pending,"q%d.receipt.pending",cycle);
    (void)snprintf(name,sizeof name,"q%d.receipt",cycle);
    if(write_new(pending,receipt,(size_t)size)) return -1;
    /* Publish complete receipt once; never overwrite a prior file/symlink. */
    if(syscall(SYS_renameat2,runtime.output,pending,runtime.output,name,1u)) return -1;
    return fsync(runtime.output);
}
static int wait_ack(void *unused,unsigned slot,int cycle,uint64_t deadline) {
    (void)unused;char name[64],expected[64],buffer[ABC_RECEIPT_CAP+1];
    (void)snprintf(name,sizeof name,"q%d.ack",cycle);
    int wanted=snprintf(expected,sizeof expected,"ABC_HEAP_ACK_V1 %u %d OK\n",slot,cycle);
    while(clock_ns(NULL)<deadline) {
        int fd=openat(runtime.output,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
        if(fd>=0) {
            struct stat st;ssize_t n=-1;
            if(!fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_size>0 && st.st_size<=ABC_RECEIPT_CAP)
                do {n=read(fd,buffer,sizeof buffer);} while(n<0 && errno==EINTR);
            int closed=close(fd);
            return !closed && n==wanted && !memcmp(buffer,expected,(size_t)wanted)?0:-1;
        }
        if(errno!=ENOENT) return -1;
        struct timespec delay={0,1000000};
        while(nanosleep(&delay,&delay) && errno==EINTR) {
            if(clock_ns(NULL)>=deadline) return -1;
        }
    }
    return -1;
}
static void clear_child_profiler_environment(void) {
    /* unsetenv does not change gperftools' already initialized flag values. */
    extern char **environ;
    for(size_t i=0;environ[i];) {
        if(!abc_profiler_variable(environ[i])) {++i;continue;}
        const char *end=strchr(environ[i],'=');char key[256];
        if(!end || (size_t)(end-environ[i])>=sizeof key) {++i;continue;}
        memcpy(key,environ[i],(size_t)(end-environ[i]));key[end-environ[i]]=0;
        (void)unsetenv(key);
    }
}
/* gperftools 2.15 GetUniquePathFromEnv sets only the first byte's 0x80
 * child marker after consuming HEAPPROFILE. Accept exactly that representation
 * or the original sealed absolute prefix; do not normalize or mutate environ.
 * This precondition does not replace any subsequent target/provider checks. */
static int profile_prefix_matches(const char *value,const char *expected) {
    if(!value || !value[0] || !expected || expected[0]!='/') return 0;
    unsigned char first=(unsigned char)value[0],wanted=(unsigned char)expected[0];
    return (first==wanted || first==(wanted|0x80u)) && !strcmp(value+1,expected+1);
}
unsigned abc_quiet_abi(void) {return ABC_QUIET_ABI;}
int abc_quiet_initialize(void) {
    if(runtime.init_attempted) return ABC_QUIET_BAD_INIT;
    runtime.init_attempted=1;
    context.meta.observer_preallocated_bytes=sizeof context+sizeof runtime;
    context.meta.observer_maps_bytes=2u*ABC_MAP_CAP;
    const char *arm=getenv("ABC_STACK_ARM"),*preload=getenv("LD_PRELOAD"),*output=getenv("ABC_STACK_OUTPUT"),*prefix=getenv("HEAPPROFILE");
    for(unsigned i=0;i<2;i++) if(arm && !strcmp(arm,abc_sealed_arms[i].name)) runtime.arm=&abc_sealed_arms[i];
    if(!runtime.arm || !preload || strcmp(preload,abc_sealed_library.path) || !output || strcmp(output,runtime.arm->output)) return initialization_failed(ABC_QUIET_BAD_INIT);
    char expected[PATH_MAX],actual[PATH_MAX];
    int length=snprintf(expected,sizeof expected,"%s/heap",runtime.arm->output);
    if(length<0 || length>=(int)sizeof expected || !profile_prefix_matches(prefix,expected) || getenv("HEAPPROFILESIGNAL")) return initialization_failed(ABC_QUIET_BAD_INIT);
    const char *const flags[]={"HEAP_PROFILE_ALLOCATION_INTERVAL","HEAP_PROFILE_DEALLOCATION_INTERVAL","HEAP_PROFILE_INUSE_INTERVAL","HEAP_PROFILE_TIME_INTERVAL","HEAP_PROFILE_CLEANUP","HEAP_PROFILE_MMAP","HEAP_PROFILE_ONLY_MMAP","HEAP_PROFILE_MMAP_LOG"};
    for(unsigned i=0;i<8;i++) {const char *value=getenv(flags[i]);if(!value || strcmp(value,"0")) return initialization_failed(ABC_QUIET_BAD_INIT);}
    ssize_t n=readlink("/proc/self/exe",actual,sizeof actual-1);
    if(n<0 || n==(ssize_t)sizeof actual-1) return initialization_failed(ABC_QUIET_BAD_INIT);
    actual[n]=0;
    if(strcmp(actual,abc_sealed_target.path)) return initialization_failed(ABC_QUIET_BAD_INIT);
    int files_status=open_runtime_files();
    if(files_status) return initialization_failed(files_status);
    for(unsigned i=0;i<7;i++) {
        Dl_info info;runtime.symbols[i]=dlsym(RTLD_DEFAULT,symbol_names[i]);
        if(!runtime.symbols[i] || !dladdr(runtime.symbols[i],&info) || !info.dli_fname || strcmp(info.dli_fname,abc_sealed_library.path)) return initialization_failed(ABC_QUIET_PROVIDER);
        if(i==0) runtime.base=info.dli_fbase;
        else if(info.dli_fbase!=runtime.base) return initialization_failed(ABC_QUIET_PROVIDER);
    }
    runtime.dump=(void (*)(const char *))runtime.symbols[4];
    runtime.stop=(void (*)(void))runtime.symbols[5];
    runtime.running=(int (*)(void))runtime.symbols[6];
    const struct abc_quiet_ops ops={NULL,clock_ns,provider_matches,running,dump,stop,map_read,publish,wait_ack};
    int status=abc_quiet_core_init(&context,&ops,0);
    context.meta.observer_preallocated_bytes=sizeof context+sizeof runtime;
    clear_child_profiler_environment();
    if(status) release_runtime_files();
    return status;
}
int abc_quiet_after_gauge(int cycle,uint64_t gauge_dart_us) {return abc_quiet_core_after_gauge(&context,cycle,gauge_dart_us);}
int abc_quiet_stop(void) {
    int result=abc_quiet_core_stop(&context);
    release_runtime_files();
    return context.meta.observer_fd_cleanup_failure?ABC_QUIET_IO:result;
}
const struct abc_quiet_metadata *abc_quiet_metadata(void) {return &context.meta;}
