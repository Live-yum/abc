#ifndef ABC_REGION_H
#define ABC_REGION_H
#include "abc_engine.h"
/* All entry points run on the shared engine isolate. Results use abc_free.
 * Input world is immutable; no candidate is returned on a failed operation.
 * Additional immutable sources: recordSourceId=2, objectSourceId=3. */
ABC_EXPORT int32_t abc_region_operation(const uint8_t*,uint32_t,const char*,const char*,const uint8_t*,uint32_t,const uint8_t*,uint32_t,uint8_t**,uint32_t*);
ABC_EXPORT int32_t abc_region_read(const uint8_t*,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint8_t**,uint32_t*);
ABC_EXPORT int32_t abc_region_pixel(const uint8_t*,uint32_t,int32_t,int32_t,uint32_t,uint32_t,const uint8_t*,uint32_t,const uint16_t*,uint8_t**,uint32_t*);
ABC_EXPORT int32_t abc_region_objects(const uint8_t*,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,uint8_t**,uint32_t*);
ABC_EXPORT int32_t abc_region_replace(const uint8_t*,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,const uint8_t*,uint32_t,uint8_t**,uint32_t*);
ABC_EXPORT void abc_region_free(void*);
ABC_EXPORT int32_t abc_region_match(const uint32_t*,uint32_t,const uint32_t*,uint32_t,uint32_t,uint32_t*);
#endif
