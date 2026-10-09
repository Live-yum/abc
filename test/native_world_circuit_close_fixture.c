/* Strict ownership fixture: failed closes keep their native owner live. */
#include <stdint.h>
#include <string.h>

static uint32_t metrics[7];
static uint32_t circuit_failures, world_failures, command_kind, output_sent;
static uint8_t output[] = {97, 98, 99};

void close_test_configure(uint32_t circuit, uint32_t world) {
  memset(metrics, 0, sizeof(metrics));
  circuit_failures = circuit; world_failures = world;
  command_kind = output_sent = 0;
}
uint32_t close_test_metric(uint32_t index) { return metrics[index]; }
const char *abc_engine_build_info(void) {
  return "{\"circuitWorldAbiVersion\":2}";
}
int32_t abc_world_open(const uint8_t *bytes, uint32_t size, uint32_t *out) {
  if (metrics[2]) return -90;
  metrics[2] = 1; *out = 1; return 0;
}
int32_t abc_world_stream_open_begin(uint32_t source, uint32_t size,
    uint32_t *out) { *out = 11; return 0; }
int32_t abc_world_stream_step(uint32_t task, uint32_t budget,
    uint32_t *event, uint8_t **data) {
  memset(event, 0, 12 * sizeof(uint32_t));
  event[0] = 1; event[1] = 4; *data = 0; return 0;
}
int32_t abc_world_stream_adopt(uint32_t task, uint32_t source, uint32_t *out) {
  if (metrics[2]) return -90;
  metrics[2] = 1; *out = 1; return 0;
}
int32_t abc_world_stream_close(uint32_t task) { return 0; }
int32_t abc_world_stream_cancel(uint32_t task) { return 0; }
int32_t abc_world_circuit_begin(uint32_t world, uint32_t scratch,
    uint32_t budget, uint32_t *out) {
  if (!metrics[2] || metrics[3]) return -93;
  metrics[3] = 1; command_kind = output_sent = 0; *out = 7; return 0;
}
int32_t abc_world_circuit_command(uint32_t id, const uint32_t *words,
    const uint32_t *records) {
  ++metrics[4];
  if (!metrics[3]) return -94;
  command_kind = words[1]; output_sent = 0; return 0;
}
int32_t abc_world_circuit_step(uint32_t id, uint32_t budget,
    uint32_t *event, uint8_t **data) {
  memset(event, 0, 12 * sizeof(uint32_t)); event[0] = 2; *data = 0;
  if (command_kind == 6 && !output_sent) {
    event[1] = 2; event[2] = 3; event[4] = sizeof(output); *data = output;
  } else {
    event[1] = 4; event[9] = command_kind;
    event[10] = command_kind == 6 ? sizeof(output) : 0;
  }
  return 0;
}
int32_t abc_world_circuit_ack(uint32_t id) { output_sent = 1; return 0; }
int32_t abc_world_circuit_stats(uint32_t id, uint32_t *stats) {
  memset(stats, 0, 24 * sizeof(uint32_t)); stats[0] = 2; return 0;
}
int32_t abc_world_circuit_cancel(uint32_t id) { ++metrics[5]; return 0; }
int32_t abc_world_circuit_close(uint32_t id) {
  ++metrics[0];
  if (!metrics[3]) { ++metrics[6]; return -82; }
  if (circuit_failures) { --circuit_failures; return -81; }
  metrics[3] = 0; return 0;
}
int32_t abc_world_close(uint32_t world) {
  ++metrics[1];
  if (metrics[3]) return -93;
  if (!metrics[2]) { ++metrics[6]; return -92; }
  if (world_failures) { --world_failures; return -91; }
  metrics[2] = 0; return 0;
}
