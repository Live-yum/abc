#ifndef ABC_WORLD_CIRCUIT_H
#define ABC_WORLD_CIRCUIT_H
#include "abc_engine.h"
/* Pointer-free wire descriptors. All calls on the owning engine isolate.
 * Event: 12 words with reserved word 5 zero. Borrowed data returned separately
 * and copied before ack. Command: 16 words, word 9 zero; records separate. */
ABC_EXPORT int32_t abc_world_circuit_begin(uint32_t world,uint32_t scratch,uint32_t twld,uint32_t twld_size,uint32_t budget,uint32_t* handle);
ABC_EXPORT int32_t abc_world_circuit_step(uint32_t handle,uint32_t work,uint32_t* words,const uint8_t** data);
ABC_EXPORT int32_t abc_world_circuit_supply(uint32_t handle,uint32_t source,uint32_t offset,const uint8_t* bytes,uint32_t length);
ABC_EXPORT int32_t abc_world_circuit_ack(uint32_t handle);
ABC_EXPORT int32_t abc_world_circuit_command(uint32_t handle,const uint32_t* words,const uint32_t* records);
ABC_EXPORT int32_t abc_world_circuit_stats(uint32_t handle,uint32_t* words);
ABC_EXPORT int32_t abc_world_circuit_cancel(uint32_t handle);
ABC_EXPORT int32_t abc_world_circuit_close(uint32_t handle);
#endif
