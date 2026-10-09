#ifndef ABC_CIRCUIT_H
#define ABC_CIRCUIT_H
#include "abc_engine.h"
/* Original host adapter. Cells are x,y,wireMask,routing uint32 records.
 * Only ordinary wiring/routing is accepted by this bounded editor. Reached
 * coordinates are flattened y*width+x, including the seed for visual traces. */
ABC_EXPORT int32_t abc_circuit_propagate(uint32_t width, uint32_t height,
 const uint32_t* cells, uint32_t count, uint32_t x, uint32_t y, uint32_t colour,
 uint32_t* reached, uint32_t capacity, uint32_t* out_count);
#endif
