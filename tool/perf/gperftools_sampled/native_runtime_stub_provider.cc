/* OFFLINE TEST ONLY. Synthetic API-shaped provider, never libtcmalloc.
 * Private libc forwarding functions are test scaffolding only. */
#include <gperftools/malloc_extension.h>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
extern "C" void *__libc_malloc(size_t);
extern "C" void *__libc_calloc(size_t, size_t);
extern "C" void *__libc_realloc(void *, size_t);
extern "C" void __libc_free(void *);
extern "C" void *malloc(size_t n) { return __libc_malloc(n); }
extern "C" void *calloc(size_t n, size_t m) { return __libc_calloc(n, m); }
extern "C" void *realloc(void *p, size_t n) { return __libc_realloc(p, n); }
extern "C" void free(void *p) { __libc_free(p); }
static bool scenario(const char *name) {
  const char *value = getenv("ABC_STUB_SCENARIO");
  return value && !strcmp(value, name);
}
class SyntheticProvider final : public MallocExtension {
 public:
  Ownership GetOwnership(const void *p) override { return p && !scenario("unowned") ? kOwned : kNotOwned; }
  void GetHeapSample(std::string *out) override {
    if (!out->empty()) std::abort();
    if (scenario("sample-throw")) throw std::runtime_error("synthetic failure");
    if (scenario("sample-empty")) return;
    if (scenario("sample-oversize")) { out->append(1048576, 'x'); return; }
    out->append("heap profile: 1: 64 [1: 64] @ heap_v2/524288\n1: 64 [1: 64] @ 0x1001\n\nMAPPED_LIBRARIES:\n00001000-00002000 r-xp 00000000 00:00 1 /offline/synthetic-provider\n");
  }
} provider;
MallocExtension *MallocExtension::instance() { return scenario("null-provider") ? nullptr : &provider; }
