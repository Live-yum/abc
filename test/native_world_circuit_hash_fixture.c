/* Host contract fixture: circuit I/O is scripted, SHA-256 is production code. */
#include <stdint.h>
#include <string.h>

#include "terra_hash.h"

#ifndef HASH_EXPORTS
#define HASH_EXPORTS 15
#endif

#define HASH_WINDOW (1024u * 1024u)

static uint32_t counters[13];
static uint32_t failure;
static int32_t failure_status;
static int32_t destroy_status;
static uint32_t output_length;
static uint32_t output_offset;
static uint32_t command_kind;
static const uint8_t *first_input;
static uint8_t output[HASH_WINDOW];

uint32_t hash_test_metric(uint32_t index) { return counters[index]; }

void hash_test_configure(uint32_t stage, int32_t status,
    int32_t cleanup_status, uint32_t length) {
  /* Do not hide an outstanding context when configuring the next operation. */
  uint32_t active = counters[4];
  memset(counters, 0, sizeof(counters));
  counters[4] = active;
  failure = stage;
  failure_status = status;
  destroy_status = cleanup_status;
  output_length = length;
  output_offset = 0;
  command_kind = 0;
  first_input = 0;
}

#if HASH_EXPORTS & 1
int32_t abc_sha256_create(uint32_t *out) {
  ++counters[0];
  if (*out != 0) ++counters[12];
  /* An error is permitted to leave the output argument untouched. */
  if (failure == 1) return failure_status;
  if (failure == 5) return 0;
  int32_t status = terra_sha256_create(out);
  if (status == 0) ++counters[4];
  if (failure == 2) return failure_status;
  return status;
}
#endif

#if HASH_EXPORTS & 2
int32_t abc_sha256_update(uint32_t handle, const uint8_t *bytes,
    uint32_t length) {
  ++counters[1];
  counters[5] += length;
  if (length > counters[6]) counters[6] = length;
  if (first_input && first_input != bytes) ++counters[7];
  first_input = bytes;
  if (failure == 3) return failure_status;
  return terra_sha256_update(handle, bytes, length);
}
#endif

#if HASH_EXPORTS & 4
int32_t abc_sha256_final(uint32_t handle, uint8_t *digest) {
  ++counters[2];
  if (failure == 4) return failure_status;
  return terra_sha256_final(handle, digest);
}
#endif

#if HASH_EXPORTS & 8
int32_t abc_sha256_destroy(uint32_t handle) {
  ++counters[3];
  int32_t status = terra_sha256_destroy(handle);
  if (status == 0) --counters[4];
  /* Inject the diagnostic after releasing the real context. */
  return destroy_status != 0 ? destroy_status : status;
}
#endif

const char *abc_engine_build_info(void) {
  return "{\"circuitWorldAbiVersion\":2}";
}

int32_t abc_world_open(const uint8_t *bytes, uint32_t size, uint32_t *out) {
  *out = 1; return 0;
}

int32_t abc_world_stream_open_begin(uint32_t source, uint32_t length,
    uint32_t *out) {
  ++counters[8]; *out = 11; return 0;
}

int32_t abc_world_stream_step(uint32_t task, uint32_t budget,
    uint32_t *event, uint8_t **data) {
  memset(event, 0, 12 * sizeof(uint32_t));
  event[0] = 1; event[1] = 4; *data = 0; return 0;
}

int32_t abc_world_stream_adopt(uint32_t task, uint32_t source, uint32_t *out) {
  *out = 1; return 0;
}

int32_t abc_world_stream_cancel(uint32_t task) { return 0; }
int32_t abc_world_stream_close(uint32_t task) { return 0; }

int32_t abc_world_circuit_begin(uint32_t world, uint32_t scratch,
    uint32_t budget, uint32_t *out) {
  command_kind = 0; *out = 7; return 0;
}

int32_t abc_world_circuit_command(uint32_t id, const uint32_t *words,
    const uint32_t *records) {
  command_kind = words[1]; output_offset = 0; return 0;
}

int32_t abc_world_circuit_step(uint32_t id, uint32_t budget,
    uint32_t *event, uint8_t **data) {
  memset(event, 0, 12 * sizeof(uint32_t));
  event[0] = 2; *data = 0;
  if (command_kind == 6 && output_offset < output_length) {
    uint32_t length = output_length - output_offset;
    if (length > HASH_WINDOW) length = HASH_WINDOW;
    for (uint32_t i = 0; i < length; ++i) {
      output[i] = (uint8_t)((output_offset + i) * 13u + 7u);
    }
    event[1] = 2; event[2] = 3; event[3] = output_offset;
    event[4] = length; *data = output; output_offset += length;
  } else {
    event[1] = 4; event[9] = command_kind;
    event[10] = command_kind == 6 ? output_length : 0;
  }
  return 0;
}

int32_t abc_world_circuit_ack(uint32_t id) { return 0; }
int32_t abc_world_circuit_stats(uint32_t id, uint32_t *stats) {
  memset(stats, 0, 24 * sizeof(uint32_t)); stats[0] = 2; return 0;
}
int32_t abc_world_circuit_cancel(uint32_t id) { ++counters[11]; return 0; }
int32_t abc_world_circuit_close(uint32_t id) { ++counters[10]; return 0; }
int32_t abc_world_close(uint32_t world) { ++counters[9]; return 0; }
