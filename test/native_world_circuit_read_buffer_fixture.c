/* Scripted host READ contract. The supply functions verify every input byte
 * synchronously, as the production stream/circuit APIs consume their input. */
#include <stdint.h>
#include <string.h>

#define WINDOW (1024u * 1024u)
static uint8_t scratch[WINDOW];
static uint32_t metrics[10];
static uint32_t decode_reads, circuit_reads, bad_range, fail_supply;
static uint32_t decode_index, circuit_index, command_kind;
static const uint8_t *decode_pointer, *circuit_pointer;
static const uint32_t offsets[] = {1, 0, 64, 0};
static const uint32_t lengths[] = {7, WINDOW, 31, WINDOW};

void read_test_configure(uint32_t decode, uint32_t circuit,
    uint32_t invalid, uint32_t failure) {
  memset(metrics, 0, sizeof(metrics));
  decode_reads = decode; circuit_reads = circuit;
  bad_range = invalid; fail_supply = failure;
  decode_index = circuit_index = command_kind = 0;
  decode_pointer = circuit_pointer = 0;
  for (uint32_t i = 0; i < WINDOW; ++i) scratch[i] = (uint8_t)(i * 31u + 17u);
}
uint32_t read_test_metric(uint32_t index) { return metrics[index]; }
const char *abc_engine_build_info(void) {
  return "{\"circuitWorldAbiVersion\":2}";
}
int32_t abc_world_open(const uint8_t *bytes, uint32_t size, uint32_t *out) {
  *out = 1; return 0;
}
int32_t abc_world_stream_open_begin(uint32_t source, uint32_t length,
    uint32_t *out) { *out = 11; return 0; }
int32_t abc_world_stream_step(uint32_t task, uint32_t budget,
    uint32_t *event, uint8_t **data) {
  memset(event, 0, 12 * sizeof(uint32_t)); *data = 0;
  event[0] = 1;
  if (decode_reads && decode_index < 4) {
    event[1] = 1; event[2] = 1;
    event[3] = offsets[decode_index];
    event[4] = bad_range ? WINDOW + 1 : lengths[decode_index];
  } else event[1] = 4;
  return 0;
}
static int32_t supply(const uint8_t *bytes, uint32_t offset, uint32_t length,
    uint32_t metric, const uint8_t **previous) {
  ++metrics[metric]; metrics[metric + 1] += length;
  if (*previous && *previous != bytes) ++metrics[4];
  *previous = bytes;
  for (uint32_t i = 0; i < length; ++i) {
    if (bytes[i] != (uint8_t)((offset + i) * 31u + 17u)) return -91;
  }
  if (fail_supply) return -92;
  return 0;
}
int32_t abc_world_stream_supply(uint32_t task, uint32_t source,
    uint32_t offset, const uint8_t *bytes, uint32_t length) {
  ++decode_index; return supply(bytes, offset, length, 0, &decode_pointer);
}
int32_t abc_world_stream_adopt(uint32_t task, uint32_t source, uint32_t *out) {
  *out = 1; return 0;
}
int32_t abc_world_stream_cancel(uint32_t task) { ++metrics[5]; return 0; }
int32_t abc_world_stream_close(uint32_t task) { ++metrics[6]; return 0; }
int32_t abc_world_circuit_begin(uint32_t world, uint32_t scratch_source,
    uint32_t budget, uint32_t *out) { *out = 7; return 0; }
int32_t abc_world_circuit_command(uint32_t id, const uint32_t *words,
    const uint32_t *records) {
  command_kind = words[1]; circuit_index = 0; circuit_pointer = 0; return 0;
}
int32_t abc_world_circuit_step(uint32_t id, uint32_t budget,
    uint32_t *event, uint8_t **data) {
  memset(event, 0, 12 * sizeof(uint32_t)); *data = 0;
  event[0] = 2;
  if (circuit_reads && circuit_index == 0) {
    event[1] = 2; event[2] = 2; event[4] = WINDOW; *data = scratch;
  } else if (circuit_reads && circuit_index <= 4) {
    event[1] = 1; event[2] = 2;
    event[3] = offsets[circuit_index - 1];
    event[4] = bad_range ? WINDOW + 1 : lengths[circuit_index - 1];
  } else {
    event[1] = 4; event[9] = command_kind;
  }
  return 0;
}
int32_t abc_world_circuit_supply(uint32_t id, uint32_t source,
    uint32_t offset, const uint8_t *bytes, uint32_t length) {
  ++circuit_index; return supply(bytes, offset, length, 2, &circuit_pointer);
}
int32_t abc_world_circuit_ack(uint32_t id) { ++circuit_index; return 0; }
int32_t abc_world_circuit_stats(uint32_t id, uint32_t *stats) {
  memset(stats, 0, 24 * sizeof(uint32_t)); stats[0] = 2; return 0;
}
int32_t abc_world_circuit_cancel(uint32_t id) { ++metrics[7]; return 0; }
int32_t abc_world_circuit_close(uint32_t id) { ++metrics[8]; return 0; }
int32_t abc_world_close(uint32_t world) { ++metrics[9]; return 0; }
