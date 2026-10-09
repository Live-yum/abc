#include "abc_circuit_rules.h"
#include "terra_circuit.h"

_Static_assert(sizeof(TerraCircuitCell) == 4 * sizeof(uint32_t), "cell ABI");
_Static_assert(sizeof(TerraCircuitPoint) == 2 * sizeof(uint32_t), "seed ABI");
_Static_assert(sizeof(TerraCircuitEvent) == 4 * sizeof(uint32_t), "event ABI");
_Static_assert(sizeof(TerraCircuitStep) == 4 * sizeof(uint32_t), "step ABI");
_Static_assert(sizeof(TerraCircuitStats) == 16 * sizeof(uint32_t), "stats ABI");

uint32_t abc_circuit_rules_abi_version(void) {
 return terra_circuit_abi_version();
}
int32_t abc_circuit_rules_create(uint32_t width, uint32_t height,
 uint32_t max_cells, uint32_t max_bytes, uint32_t* out_handle) {
 return terra_circuit_create(width, height, max_cells, max_bytes, out_handle);
}
int32_t abc_circuit_rules_load(uint32_t handle, const uint32_t* records,
 uint32_t count) {
 if (count > 4096) return TERRA_CIRCUIT_LIMIT;
 return terra_circuit_load(handle, (const TerraCircuitCell*)records, count);
}
int32_t abc_circuit_rules_compile(uint32_t handle, uint32_t max_cells,
 uint32_t* out_compiled) {
 if (max_cells > 4096) return TERRA_CIRCUIT_LIMIT;
 return terra_circuit_compile(handle, max_cells, out_compiled);
}
int32_t abc_circuit_rules_patch(uint32_t handle, const uint32_t* records,
 uint32_t count) {
 if (count > 4096) return TERRA_CIRCUIT_LIMIT;
 return terra_circuit_patch(handle, (const TerraCircuitCell*)records, count);
}
int32_t abc_circuit_rules_begin(uint32_t handle, const uint32_t* points,
 uint32_t count, uint32_t colour, uint32_t flags, uint32_t work_limit) {
 if (count > 8192) return TERRA_CIRCUIT_LIMIT;
 return terra_circuit_begin(handle, (const TerraCircuitPoint*)points, count,
  colour, flags, work_limit);
}
int32_t abc_circuit_rules_step(uint32_t handle, uint32_t max_nodes,
 uint32_t* events, uint32_t event_capacity, uint32_t* out_step) {
 if (max_nodes > 4096 || event_capacity > 4096) return TERRA_CIRCUIT_LIMIT;
 return terra_circuit_step(handle, max_nodes, (TerraCircuitEvent*)events,
  event_capacity, (TerraCircuitStep*)out_step);
}
int32_t abc_circuit_rules_stats(uint32_t handle, uint32_t* out_stats) {
 return terra_circuit_stats(handle, (TerraCircuitStats*)out_stats);
}
int32_t abc_circuit_rules_cancel(uint32_t handle) {
 return terra_circuit_cancel(handle);
}
int32_t abc_circuit_rules_close(uint32_t handle) {
 return terra_circuit_close(handle);
}
