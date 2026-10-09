#ifndef ABC_ENGINE_H
#define ABC_ENGINE_H
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
#define ABC_EXPORT __declspec(dllexport)
#else
#define ABC_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif
#ifdef __cplusplus
extern "C" {
#endif
ABC_EXPORT uint32_t abc_engine_abi_version(void);
ABC_EXPORT const char* abc_engine_build_info(void);
ABC_EXPORT void* abc_alloc(size_t size);
ABC_EXPORT void abc_free(void* pointer);
/* Optional incremental SHA-256. Opaque contexts and caller-owned buffers; all
 * calls remain serialized on the engine's owning isolate. */
ABC_EXPORT int32_t abc_sha256_create(uint32_t* handle);
ABC_EXPORT int32_t abc_sha256_update(uint32_t handle,const uint8_t* bytes,uint32_t length);
ABC_EXPORT int32_t abc_sha256_final(uint32_t handle,uint8_t* digest_32);
ABC_EXPORT int32_t abc_sha256_destroy(uint32_t handle);
ABC_EXPORT int32_t abc_error(char* out,uint32_t capacity,uint32_t* required);
ABC_EXPORT int32_t abc_world_open(const uint8_t* bytes,uint32_t size,uint32_t* handle);
ABC_EXPORT int32_t abc_world_close(uint32_t handle);
ABC_EXPORT int32_t abc_world_section(uint32_t handle,const char* section,char* out,uint32_t capacity,uint32_t* required);
ABC_EXPORT int32_t abc_world_operation(uint32_t handle,const char* operation,const char* json,char* out,uint32_t capacity,uint32_t* required);
ABC_EXPORT int32_t abc_world_save(uint32_t handle,uint8_t* out,uint32_t capacity,uint32_t* required);
ABC_EXPORT int32_t abc_world_thumbnail(uint32_t handle,uint8_t* out,uint32_t capacity,uint32_t* required,uint32_t* width,uint32_t* height);
ABC_EXPORT int32_t abc_world_map(uint32_t handle,uint8_t* out,uint32_t capacity,uint32_t* required,uint32_t* width,uint32_t* height);
ABC_EXPORT int32_t abc_player_open(const uint8_t* bytes,uint32_t size,uint32_t* handle);
ABC_EXPORT int32_t abc_player_open_json(const char* json,uint32_t* handle);
ABC_EXPORT int32_t abc_player_set_many(uint32_t handle,const char* edits_json);
ABC_EXPORT int32_t abc_player_close(uint32_t handle);
ABC_EXPORT int32_t abc_player_json(uint32_t handle,char* out,uint32_t capacity,uint32_t* required);
ABC_EXPORT int32_t abc_player_set(uint32_t handle,const char* pointer,const char* value_json);
ABC_EXPORT int32_t abc_player_patch(uint32_t handle,const char* patch_json);
ABC_EXPORT int32_t abc_player_save(uint32_t handle,uint8_t* out,uint32_t capacity,uint32_t* required);
#ifdef __cplusplus
}
#endif
#endif
