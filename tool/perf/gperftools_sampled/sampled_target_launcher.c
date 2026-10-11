/* Sampled-only sealed target launcher. Offline tests use an inert ELF + an
 * explicitly synthetic provider. No default target, full-profiler controls,
 * second arm, q7, retry, SDK command, compiler, or application orchestration. */
#define _GNU_SOURCE
#include "native_identity.h"
#ifndef ABC_SAMPLE_SEALED_CONFIG
#error "Pass an explicit sampled-only seal header"
#endif
#include ABC_SAMPLE_SEALED_CONFIG
#ifndef ABC_SAMPLE_HAS_SEALED_HELPER
#error "Launcher seal must include the already-built helper's actual SHA"
#endif
extern char **environ;
static int target=-1, library=-1, helper=-1, output=-1, once=-1;
static int close_once(int *fd) {
    if (*fd<0) return 0;
    int old=*fd;*fd=-1;
    return close(old);
}
static int reject(const char *why) {
    close_once(&once);close_once(&output);close_once(&helper);close_once(&library);close_once(&target);
    dprintf(STDERR_FILENO,"ABC_SAMPLED_LAUNCH_REJECT %s\n",why);
    return 78;
}
int main(int argc, char **argv) {
    (void)argc;
    /* A DSO already loaded into this process cannot be removed retroactively.
     * The parent must also start compilers and the driver with a clean env. */
    for(char **p=environ;p && *p;++p)
        if(!strncmp(*p,"LD_",3) || !strncmp(*p,"HEAP",4) ||
           !strncmp(*p,"TCMALLOC",8) || !strncmp(*p,"CPUPROFILE",10) ||
           !strncmp(*p,"MALLOC",6) || !strncmp(*p,"ABC_STACK_",10))
            return reject("launcher-not-clean");
#ifndef ABC_SAMPLE_OFFLINE_TESTING
    if(strcmp(abc_sample_sealed_library.path,"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16"))
        return reject("official-library-path");
#endif
    if(strcmp(abc_sample_sealed_helper.path,abc_sample_sealed_helper_path)) return reject("helper-path");
    target=abc_open_identity(&abc_sample_sealed_target,1);
    if(target<0) return reject("target-identity");
    library=abc_open_identity(&abc_sample_sealed_library,0);
    if(library<0) return reject("library-identity");
    helper=abc_open_identity(&abc_sample_sealed_helper,0);
    if(helper<0) return reject("helper-identity");
    output=abc_open_output(&abc_sample_sealed_output);
    if(output<0) return reject("output-identity");
    unsigned char magic[4];
    if(read(target,magic,sizeof magic)!=(ssize_t)sizeof magic || memcmp(magic,"\177ELF",sizeof magic) ||
       lseek(target,0,SEEK_SET)<0) return reject("target-not-ELF");
    char preload[PATH_MAX+32],helper_env[PATH_MAX+32],output_env[PATH_MAX+32];
    char hello[PATH_MAX+64],ready[PATH_MAX+64];
#define ABC_FORMAT(buffer, ...) do { int n=snprintf(buffer,sizeof buffer,__VA_ARGS__); if(n<0 || n>=(int)sizeof buffer) return reject("path-length"); } while(0)
    ABC_FORMAT(preload,"LD_PRELOAD=%s",abc_sample_sealed_library.path);
    ABC_FORMAT(helper_env,"ABC_SAMPLED_HELPER=%s",abc_sample_sealed_helper_path);
    ABC_FORMAT(output_env,"ABC_SAMPLED_OUTPUT=%s",abc_sample_sealed_output.output);
    ABC_FORMAT(hello,"ABC_SAMPLED_HELLO=%s/sampled-hello.json",abc_sample_sealed_output.output);
    ABC_FORMAT(ready,"ABC_SAMPLED_READY=%s/sampled-ready.json",abc_sample_sealed_output.output);
    char *env[2048];size_t count=0;
    for(char **p=environ;p && *p;++p) {
        if(abc_profiler_variable(*p) || !strncmp(*p,"ABC_STACK_",10) || !strncmp(*p,"ABC_SAMPLED_",12)) continue;
        if(count>=sizeof env/sizeof env[0]-8) return reject("environment-cap");
        env[count++]=*p;
    }
    env[count++]=preload;env[count++]=helper_env;env[count++]=output_env;
    env[count++]=hello;env[count++]=ready;
    env[count++]="ABC_SAMPLED_DIAGNOSTIC=1";
    env[count++]="TCMALLOC_SAMPLE_PARAMETER=524288";
    env[count]=NULL;
    /* O_EXCL is an at-most-one launch reservation. Failure consumes it too.
     * We do not delete a token or retry another target after failed exec. */
    once=openat(output,"launch.once",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(once<0) return reject("once-token");
    char record[128];
    int n=snprintf(record,sizeof record,"ABC_SAMPLED_LAUNCH_ONCE_V1 %ld sampled-q0\n",(long)getpid());
    struct stat st;
    if(n<=0 || n>=(int)sizeof record || fstat(once,&st) || !S_ISREG(st.st_mode) ||
       st.st_uid!=geteuid() || (st.st_mode&07777)!=0600 || st.st_nlink!=1 || st.st_size ||
       write(once,record,(size_t)n)!=n || fsync(once)) return reject("token-write");
    if(close_once(&once) || fsync(output)) return reject("token-sync");
    if(close_once(&output) || close_once(&helper) || close_once(&library)) return reject("close");
    /* Exact verified ELF inode, same PID/argv. The dynamic loader still opens
     * the canonical preloaded DSO path: seals are repeated observations, not
     * an immutable namespace or an atomic anti-tampering guarantee. */
    fexecve(target,argv,env);
    return reject("exec-failed-token-retained");
}
