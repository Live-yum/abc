/* Sealed target-only exec launcher. Build requires an explicit audited header.
 * Offline tests seal an inert ELF and an inert DSO, never an application.
 */
#define _GNU_SOURCE
#include "native_identity.h"
#ifndef ABC_SEALED_CONFIG
#error "Pass -DABC_SEALED_CONFIG=\"absolute/generated/header.h\"; no live defaults"
#endif
#include ABC_SEALED_CONFIG
#include <inttypes.h>
extern char **environ;

static int reject(const char *why) { dprintf(STDERR_FILENO,"ABC_LAUNCH_REJECT %s\n",why);return 78; }
int main(int argc, char **argv) {
    (void)argc;
    /* A loaded library cannot be retroactively removed. Reject a dirty
     * launcher entry; the supervisor must keep compiler/driver/launcher clean. */
    if(getenv("LD_PRELOAD") || getenv("LD_AUDIT")) return reject("launcher-not-clean");
    const char *name=getenv("ABC_STACK_ARM");
    const struct abc_arm_identity *arm=NULL;
    if(!name || (strcmp(name,"probe-only") && strcmp(name,"product-with-ownership"))) return reject("arm");
    for(unsigned i=0;i<2;i++) if(!strcmp(name,abc_sealed_arms[i].name)) arm=&abc_sealed_arms[i];
    if(!arm) return reject("unsealed-arm");
#ifndef ABC_OFFLINE_TESTING
    if(strcmp(abc_sealed_library.path,"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16")) return reject("full-library-path");
#endif
    int target=abc_open_identity(&abc_sealed_target,1);
    if(target<0) return reject("target-identity");
    int library=abc_open_identity(&abc_sealed_library,0);
    if(library<0) {close(target);return reject("library-identity");}
    int output=abc_open_output(arm);
    if(output<0) {close(target);close(library);return reject("output-identity");}
    unsigned char magic[4];
    if(read(target,magic,4)!=4 || memcmp(magic,"\177ELF",4)) return reject("target-not-ELF");
    if(lseek(target,0,SEEK_SET)<0) return reject("target-rewind");
    char preload[PATH_MAX+32],prefix[PATH_MAX+32],output_env[PATH_MAX+32];
    if(snprintf(preload,sizeof preload,"LD_PRELOAD=%s",abc_sealed_library.path)>=(int)sizeof preload ||
       snprintf(prefix,sizeof prefix,"HEAPPROFILE=%s/heap",arm->output)>=(int)sizeof prefix ||
       snprintf(output_env,sizeof output_env,"ABC_STACK_OUTPUT=%s",arm->output)>=(int)sizeof output_env) return reject("path-length");
    char *env[2048];size_t count=0;
    for(char **p=environ;*p;p++) {
        if(abc_profiler_variable(*p)) continue;
        if(count>=sizeof env/sizeof env[0]-13) return reject("environment-cap");
        env[count++]=*p;
    }
    env[count++]=preload;env[count++]=prefix;env[count++]=output_env;
    env[count++]="HEAP_PROFILE_ALLOCATION_INTERVAL=0";
    env[count++]="HEAP_PROFILE_DEALLOCATION_INTERVAL=0";
    env[count++]="HEAP_PROFILE_INUSE_INTERVAL=0";
    env[count++]="HEAP_PROFILE_TIME_INTERVAL=0";
    env[count++]="HEAP_PROFILE_CLEANUP=0";
    env[count++]="HEAP_PROFILE_MMAP=0";
    env[count++]="HEAP_PROFILE_ONLY_MMAP=0";
    env[count++]="HEAP_PROFILE_MMAP_LOG=0";
    env[count]=NULL;
    /* Reserve only after all read-only identity checks, never remove a token.
     * An exec failure also consumes it: a retry cannot create another target. */
    int once=openat(output,"launch.once",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(once<0) return reject("once-token");
    char record[128];int n=snprintf(record,sizeof record,"ABC_LAUNCH_ONCE_V1 %ld %s\n",(long)getpid(),arm->name);
    if(n<0 || n>=(int)sizeof record || write(once,record,(size_t)n)!=n || fsync(once) || close(once)) return reject("token-write");
    if(fsync(output)) return reject("token-directory-sync");
    close(output);close(library);
    /* fd-bound execve preserves PID and the exact argv from Flutter, including
     * argv[0]. The kernel executes the original verified bundle inode. */
    fexecve(target,argv,env);
    return reject("exec-failed-token-retained");
}
