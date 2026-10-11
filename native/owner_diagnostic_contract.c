/* Small deterministic contracts only; no real WLD, Flutter, or benchmark.
 * Compile one of ABC_OWNER_STUB_CONTRACT / ABC_OWNER_LIBC_CONTRACT, or link
 * the real diagnostic engine and pass assets/qa/synthetic-circuit.wld. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "owner contract line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

#ifdef ABC_OWNER_LIBC_CONTRACT
#include <malloc.h>
extern int abc_retention_initialize_v1(void);
extern int abc_retention_snapshot_v1(uint64_t*, size_t);
int main(void) {
    uint64_t out[16], invalid[16], before[16];
    memset(invalid, 0xa5, sizeof(invalid)); memcpy(before, invalid, sizeof(invalid));
    REQUIRE(abc_retention_snapshot_v1(NULL, 16) == -1);
    REQUIRE(abc_retention_snapshot_v1(invalid, 15) == -1);
    REQUIRE(memcmp(invalid, before, sizeof(invalid)) == 0);
    const int status = abc_retention_initialize_v1();
    REQUIRE(status >= 0 && status <= 4);
    REQUIRE(abc_retention_snapshot_v1(out, 16) == status);
    REQUIRE(out[0] == 1 && out[1] == (uint64_t)status);
    REQUIRE(out[2] == sizeof(size_t));
    if (status == 0) {
        const struct mallinfo2 m = mallinfo2();
        const uint64_t expected[10] = {m.arena,m.ordblks,m.smblks,m.hblks,
            m.hblkhd,m.usmblks,m.fsmblks,m.uordblks,m.fordblks,m.keepcost};
        REQUIRE(out[3] == sizeof(m));
        REQUIRE(memcmp(out + 6, expected, sizeof(expected)) == 0);
        REQUIRE(out[6] == out[13] + out[14]);
    } else {
        for (size_t i = 6; i < 16; ++i) REQUIRE(out[i] == UINT64_MAX);
    }
    printf("PASS libc helper ABI/header and explicit support status=%d\n", status);
    return 0;
}
#else
#include "abc_owner_diagnostics.h"
static void snapshot(uint64_t out[ABC_OWNER_DIAGNOSTICS_WORDS]) {
    uint64_t second[ABC_OWNER_DIAGNOSTICS_WORDS];
    REQUIRE(abc_owner_diagnostics_abi_version() == 1);
    REQUIRE(abc_owner_diagnostics_snapshot_v1(out, ABC_OWNER_DIAGNOSTICS_WORDS) == 0);
    REQUIRE(abc_owner_diagnostics_snapshot_v1(second, ABC_OWNER_DIAGNOSTICS_WORDS) == 0);
    REQUIRE(memcmp(out, second, sizeof(second)) == 0);
    REQUIRE(out[ABC_OWNER_ABI] == 1 && out[ABC_OWNER_WORDS] == 16);
    for (size_t i = 12; i < 16; ++i) REQUIRE(out[i] == 0);
}
static void invalid_contract(void) {
    uint64_t words[16], before[16];
    memset(words, 0xa5, sizeof(words)); memcpy(before, words, sizeof(words));
    REQUIRE(abc_owner_diagnostics_snapshot_v1(NULL, 16) == -1);
    REQUIRE(abc_owner_diagnostics_snapshot_v1(words, 15) == -1);
    REQUIRE(abc_owner_diagnostics_snapshot_v1(words, 17) == -1);
    REQUIRE(memcmp(words, before, sizeof(words)) == 0);
}
#ifdef ABC_OWNER_STUB_CONTRACT
static uint32_t bytes[4], worlds;
static int stream, checkpoint;
static uint64_t owners;
uint32_t tx_heap_used(void) { return bytes[0]; }
uint32_t tx_native_heap_used(void) { return bytes[1]; }
uint32_t tx_bridge_heap_used(void) { return bytes[2]; }
uint32_t tx_heap_peak(void) { return bytes[3]; }
uint32_t tx_get_world_open_count(void) { return worlds; }
int tx_stream_has_task(void) { return stream; }
int tx_checkpoint_active(void) { return checkpoint; }
uint64_t cx_owner_diagnostics_counts(void) { return owners; }
int main(void) {
    uint64_t out[16]; invalid_contract(); snapshot(out);
    REQUIRE(out[ABC_OWNER_TOTAL_BYTES] == 0 && out[ABC_OWNER_CENSORED_MASK] == 0);
    bytes[0]=111; bytes[1]=100; bytes[2]=11; bytes[3]=120;
    worlds=1; stream=7; checkpoint=9; owners=4 | ((uint64_t)3 << 32);
    snapshot(out);
    REQUIRE(out[2]==111 && out[3]==100 && out[4]==11 && out[5]==120);
    REQUIRE(out[6]==1 && out[7]==1 && out[8]==1 && out[9]==4 && out[10]==3);
    for (uint32_t mask=0; mask<16; ++mask) {
        for (uint32_t i=0; i<4; ++i) bytes[i]=(mask & (1u<<i)) ? UINT32_MAX : 17;
        snapshot(out); REQUIRE(out[11]==mask);
    }
    puts("PASS owner ABI: exact words, no invalid writes, stable reads, censored masks");
    return 0;
}
#else
#include "abc_world_circuit.h"
static uint8_t input[65536];
static uint32_t input_bytes;
static void counts(uint32_t world, uint32_t stream, uint32_t circuit, uint32_t vm) {
    uint64_t out[16]; snapshot(out);
    REQUIRE(out[6]==world && out[7]==stream && out[8]==0);
    REQUIRE(out[9]==circuit && out[10]==vm && out[11]==0);
    REQUIRE(out[2]==out[3]+out[4] && out[5]>=out[2]);
    REQUIRE(out[4]==0); /* No facade bridge buffer survives a serialized call. */
}
static void empty(void) {
    uint64_t out[16]; counts(0,0,0,0); snapshot(out);
    REQUIRE(out[2]==0 && out[3]==0 && out[4]==0);
}
static uint32_t open_stream(void) {
    uint32_t task=0;
    REQUIRE(abc_world_stream_open_begin(1,input_bytes,&task)==0 && task);
    return task;
}
static uint32_t adopt_stream(uint32_t task) {
    uint32_t event[12], world=0;
    const uint8_t* data=NULL;
    for (uint32_t step=0; ; ++step) {
        REQUIRE(step<10000);
        REQUIRE(abc_world_stream_step(task,4096,event,&data)>=0);
        REQUIRE(event[0]==1 && event[5]==0);
        if (event[1]==4) break;
        REQUIRE(event[1]==0 || event[1]==1);
        if (event[1]==1) {
            REQUIRE(event[2]==1 && event[3]<=input_bytes && event[4]<=input_bytes-event[3]);
            REQUIRE(abc_world_stream_supply(task,1,event[3],input+event[3],event[4])==0);
        }
    }
    REQUIRE(abc_world_stream_adopt(task,1,&world)==0 && world);
    return world;
}
static void compile_circuit(uint32_t circuit) {
    FILE* scratch=tmpfile(); REQUIRE(scratch);
    uint8_t* window=malloc(1024u*1024u); REQUIRE(window);
    uint32_t event[12]; const uint8_t* data=NULL;
    for (uint32_t step=0; ; ++step) {
        REQUIRE(step<10000);
        REQUIRE(abc_world_circuit_step(circuit,4096,event,&data)>=0);
        REQUIRE(event[0]==2 && event[5]==0);
        if (event[1]==4) break;
        REQUIRE(event[4]<=1024u*1024u);
        if (event[1]==1) {
            const uint8_t* source=window;
            if (event[2]==1) {
                REQUIRE(event[3]<=input_bytes && event[4]<=input_bytes-event[3]);
                source=input+event[3];
            } else {
                REQUIRE(event[2]==2 && fseek(scratch,(long)event[3],SEEK_SET)==0);
                REQUIRE(fread(window,1,event[4],scratch)==event[4]);
            }
            REQUIRE(abc_world_circuit_supply(circuit,event[2],event[3],source,event[4])==0);
        } else if (event[1]==2) {
            REQUIRE(event[2]==2 && data && fseek(scratch,(long)event[3],SEEK_SET)==0);
            REQUIRE(fwrite(data,1,event[4],scratch)==event[4]);
            REQUIRE(abc_world_circuit_ack(circuit)==0);
        } else REQUIRE(event[1]==0);
    }
    free(window); REQUIRE(fclose(scratch)==0);
}
int main(int argc, char** argv) {
    REQUIRE(argc==2);
    FILE* source=fopen(argv[1],"rb"); REQUIRE(source);
    const size_t n=fread(input,1,sizeof(input),source);
    REQUIRE(!ferror(source) && n>0 && n<sizeof(input) && feof(source));
    REQUIRE(fclose(source)==0); input_bytes=(uint32_t)n;
    invalid_contract(); empty();

    uint32_t task=open_stream(); counts(0,1,0,0);
    REQUIRE(abc_world_stream_cancel(task)==0);
    counts(0,1,0,0); /* CANCELLED task remains allocated until close. */
    REQUIRE(abc_world_stream_close(task)==0); empty();

    task=open_stream();
    const uint32_t world=adopt_stream(task);
    counts(1,1,0,0); /* ADOPTED task also remains until close. */
    REQUIRE(abc_world_stream_close(task)==0); counts(1,0,0,0);

    uint32_t circuit[4]={0};
    REQUIRE(abc_world_circuit_begin(world,2,192u*1024u*1024u,circuit)==0);
    counts(1,0,1,0);
    uint32_t stats[24];
    REQUIRE(abc_world_circuit_stats(circuit[0],stats)==0);
    REQUIRE(stats[2]==7 && stats[3]==32); /* Only this tiny synthetic fixture. */
    compile_circuit(circuit[0]); counts(1,0,1,1);
    for (uint32_t i=1;i<4;++i) {
        REQUIRE(abc_world_circuit_begin(world,2+i,192u*1024u*1024u,circuit+i)==0);
        counts(1,0,i+1,1);
    }
    uint32_t rejected=123;
    REQUIRE(abc_world_circuit_begin(world,6,192u*1024u*1024u,&rejected)<0);
    REQUIRE(rejected==0); counts(1,0,4,1);
    for (uint32_t i=1;i<4;++i) {
        REQUIRE(abc_world_circuit_close(circuit[i])==0);
        counts(1,0,4-i,1);
    }
    REQUIRE(abc_world_circuit_cancel(circuit[0])==0); counts(1,0,1,1);
    REQUIRE(abc_world_circuit_close(circuit[0])==0); counts(1,0,0,0);
    REQUIRE(abc_world_circuit_close(circuit[0])<0); counts(1,0,0,0);
    REQUIRE(abc_world_close(world)==0); empty();
    puts("PASS synthetic 7x32 ownership: cancel/adopt tasks, four slots, VM, close, zero Tx payload");
    return 0;
}
#endif
#endif
