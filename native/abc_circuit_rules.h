#ifndef ABC_CIRCUIT_RULES_H
#define ABC_CIRCUIT_RULES_H
#include "abc_engine.h"

/* Flat uint32 records cross the FFI boundary; JavaScript receives only copied
 * JSON values and opaque integer handles, never native pointers. */
ABC_EXPORT uint32_t abc_circuit_rules_abi_version(void);
ABC_EXPORT int32_t abc_circuit_rules_create(uint32_t width, uint32_t height,
 uint32_t max_cells, uint32_t max_bytes, uint32_t* out_handle);
ABC_EXPORT int32_t abc_circuit_rules_load(uint32_t handle,
 const uint32_t* records, uint32_t count);
ABC_EXPORT int32_t abc_circuit_rules_compile(uint32_t handle,
 uint32_t max_cells, uint32_t* out_compiled);
ABC_EXPORT int32_t abc_circuit_rules_patch(uint32_t handle,
 const uint32_t* records, uint32_t count);
ABC_EXPORT int32_t abc_circuit_rules_begin(uint32_t handle,
 const uint32_t* points, uint32_t count, uint32_t colour, uint32_t flags,
 uint32_t work_limit);
ABC_EXPORT int32_t abc_circuit_rules_step(uint32_t handle, uint32_t max_nodes,
 uint32_t* events, uint32_t event_capacity, uint32_t* out_step);
ABC_EXPORT int32_t abc_circuit_rules_stats(uint32_t handle, uint32_t* out_stats);
ABC_EXPORT int32_t abc_circuit_rules_cancel(uint32_t handle);
ABC_EXPORT int32_t abc_circuit_rules_close(uint32_t handle);
#endif
