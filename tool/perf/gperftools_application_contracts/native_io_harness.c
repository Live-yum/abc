/* Tests only the Linux file/receipt functions against synthetic byte strings.
 * No initialize/provider/dump entrypoint is called. */
#include "quiet_dump_linux.c"
static unsigned mock_stop_calls;
static void mock_stop(void) {++mock_stop_calls;}
static int mock_running(void *unused) {(void)unused;return 0;}
int main(int argc,char **argv) {
    if(argc!=3) return 2;
    if(!strncmp(argv[2],"cleanup-",8)) {
        runtime.arm=&abc_sealed_arms[0];runtime.init_attempted=1;
        int opened=open_runtime_files();unsigned held=context.meta.observer_held_fds;
        if(opened) initialization_failed(opened);
        else {
            if(!strcmp(argv[2],"cleanup-close-error")) close(runtime.target);
            runtime.stop=mock_stop;
            context.ops.clock_ns=clock_ns;context.ops.stop=stop;context.ops.running=mock_running;
            context.meta.initialized=1;context.meta.abi=ABC_QUIET_ABI;
        }
        int stopped=abc_quiet_stop();
        int sentinel=open("/dev/null",O_RDONLY|O_CLOEXEC);
        int again=abc_quiet_stop(),reinit=abc_quiet_initialize();
        int sentinel_alive=sentinel>=0 && fcntl(sentinel,F_GETFD)>=0;
        if(sentinel>=0) close(sentinel);
        printf("{\"opened\":%d,\"heldBefore\":%u,\"heldAfter\":%u,\"closed\":%u,\"closeAttempts\":%u,\"closeError\":%d,\"stop\":%d,\"again\":%d,\"reinit\":%d,\"mockStopCalls\":%u,\"sentinelAlive\":%d}\n",opened,held,context.meta.observer_held_fds,context.meta.observer_closed_fds,context.meta.observer_fd_close_attempts,context.meta.observer_fd_cleanup_failure,stopped,again,reinit,mock_stop_calls,sentinel_alive);
        return 0;
    }
    runtime.output=open(argv[1],O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    if(runtime.output<0) return 3;
    const char data[]="known synthetic maps bytes\n";
    const struct abc_quiet_cut cut={.cycle=0,.dump_start_ns=100,.dump_end_ns=200,
        .maps_before_size=sizeof data-1,.maps_after_size=sizeof data-1};
    int first=publish(NULL,0,&cut,data,data),second=-2,ack_status=-2;
    if(!strcmp(argv[2],"duplicate")) second=publish(NULL,0,&cut,data,data);
    if(!strcmp(argv[2],"ack")) {
        const char ack[]="ABC_HEAP_ACK_V1 0 0 OK\n";
        if(write_new("q0.ack",ack,sizeof ack-1)) return 4;
        ack_status=wait_ack(NULL,0,0,clock_ns(NULL)+ABC_ACK_NS);
    } else if(!strcmp(argv[2],"bad-ack")) {
        const char ack[]="ABC_HEAP_ACK_V1 1 7 OK\n";
        if(write_new("q0.ack",ack,sizeof ack-1)) return 4;
        ack_status=wait_ack(NULL,0,0,clock_ns(NULL)+ABC_ACK_NS);
    } else if(!strcmp(argv[2],"external-ack")) {
        ack_status=wait_ack(NULL,0,0,clock_ns(NULL)+10000000);
    }
    printf("{\"first\":%d,\"second\":%d,\"ack\":%d}\n",first,second,ack_status);
    close(runtime.output);return 0;
}
