// CI-only observation shim. Never linked into libabc_engine or a product bundle.
// Compile against this runner's official malloc.h; Dart sees only uint64_t words.
#define _GNU_SOURCE 1
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(__linux__) && defined(__GLIBC__)
#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <malloc.h>
#include <pthread.h>
#if __GLIBC_PREREQ(2, 33) && !defined(ABC_RETENTION_DISABLE_MALLINFO2)
#define ABC_HAS_MALLINFO2 1
#endif
#endif

#define ABC_EXPORT __attribute__((visibility("default")))
#define ABC_WORDS 16
// 0 supported; 1 headers unsupported; 2 runtime symbol unavailable;
// 3 allocation symbols belong to another DSO; 4 libc identity unverified.
static int support = 1;
static uint64_t libc_major, libc_minor;

#ifdef ABC_HAS_MALLINFO2
typedef struct mallinfo2 (*mallinfo2_function)(void);
static mallinfo2_function read_mallinfo2;
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
_Static_assert(sizeof(size_t) <= sizeof(uint64_t), "size_t exceeds wire width");
#define CHECK_FIELD(name, index) \
  _Static_assert(offsetof(struct mallinfo2, name) == (index) * sizeof(size_t), \
                 "Unexpected official mallinfo2 field layout: " #name)
CHECK_FIELD(arena, 0);
CHECK_FIELD(ordblks, 1);
CHECK_FIELD(smblks, 2);
CHECK_FIELD(hblks, 3);
CHECK_FIELD(hblkhd, 4);
CHECK_FIELD(usmblks, 5);
CHECK_FIELD(fsmblks, 6);
CHECK_FIELD(uordblks, 7);
CHECK_FIELD(fordblks, 8);
CHECK_FIELD(keepcost, 9);
_Static_assert(sizeof(struct mallinfo2) == 10 * sizeof(size_t),
               "Unexpected official mallinfo2 size");

static void initialize_once(void) {
  const char *version = gnu_get_libc_version();
  while (*version >= '0' && *version <= '9')
    libc_major = libc_major * 10 + (uint64_t)(*version++ - '0');
  if (*version == '.') ++version;
  while (*version >= '0' && *version <= '9')
    libc_minor = libc_minor * 10 + (uint64_t)(*version++ - '0');
  void *symbol = dlsym(RTLD_DEFAULT, "mallinfo2");
  if (!symbol) { support = 2; return; }
  Dl_info info, libc_info;
  void *libc_symbol = dlsym(RTLD_DEFAULT, "gnu_get_libc_version");
  if (!libc_symbol || !dladdr(libc_symbol, &libc_info) ||
      !dladdr(symbol, &info) || info.dli_fbase != libc_info.dli_fbase) {
    support = 4;
    return;
  }
  // Detect common process-wide allocator replacement. This cannot establish
  // that every library uses these symbols or account for private allocators.
  const char *allocators[] = {"malloc", "calloc", "realloc", "free"};
  for (size_t i = 0; i < sizeof(allocators) / sizeof(allocators[0]); ++i) {
    void *allocator = dlsym(RTLD_DEFAULT, allocators[i]);
    if (!allocator || !dladdr(allocator, &info)) { support = 4; return; }
    if (info.dli_fbase != libc_info.dli_fbase) { support = 3; return; }
  }
  _Static_assert(sizeof(read_mallinfo2) == sizeof(symbol),
                 "Unsupported dynamic function pointer ABI");
  memcpy(&read_mallinfo2, &symbol, sizeof(symbol));
  support = 0;
}
#endif

ABC_EXPORT int abc_retention_initialize_v1(void) {
#ifdef ABC_HAS_MALLINFO2
  if (pthread_once(&initialized, initialize_once) != 0) return 4;
#endif
  return support;
}

// The caller allocates one buffer before baseline and reuses it. No pointers,
// paths, allocation stacks, user payloads or serialized bodies cross this ABI.
// Slots 6..15 are UINT64_MAX when unsupported: the Dart layer MUST emit null.
ABC_EXPORT int abc_retention_snapshot_v1(uint64_t *out, size_t words) {
  if (!out || words != ABC_WORDS) return -1;
  const int status = abc_retention_initialize_v1();
  for (size_t i = 0; i < ABC_WORDS; ++i) out[i] = UINT64_MAX;
  out[0] = 1;
  out[1] = (uint64_t)status;
  out[2] = sizeof(size_t);
  out[3] = 0;  // Metadata only: raw measurement slots remain unavailable.
  out[4] = libc_major;
  out[5] = libc_minor;
#ifdef ABC_HAS_MALLINFO2
  out[3] = sizeof(struct mallinfo2);
  if (status == 0) {
    // glibc traverses and locks arenas separately, not one atomic whole-process
    // instant. The consumer records the elapsed call and never labels it live
    // application bytes, resident bytes, or a complete ownership census.
    const struct mallinfo2 m = read_mallinfo2();
    out[6] = m.arena;
    out[7] = m.ordblks;
    out[8] = m.smblks;
    out[9] = m.hblks;
    out[10] = m.hblkhd;
    out[11] = m.usmblks;
    out[12] = m.fsmblks;
    out[13] = m.uordblks;
    out[14] = m.fordblks;
    out[15] = m.keepcost;
  }
#endif
  return status;
}
