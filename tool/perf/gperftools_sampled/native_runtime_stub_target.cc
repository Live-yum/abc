/* OFFLINE ONLY inert ELF. No Flutter, Dart VM, application, SDK or profiler. */
#include "sample_runtime.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
  const char *path = getenv("ABC_SAMPLED_HELPER");
  if (!path) return 10;
  void *helper = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!helper) { fprintf(stderr, "%s\n", dlerror()); return 11; }
  auto initialize = reinterpret_cast<int (*)()>(dlsym(helper,"abc_sample_runtime_initialize"));
  auto capture = reinterpret_cast<int (*)(uint64_t)>(dlsym(helper,"abc_sample_runtime_q0"));
  auto close = reinterpret_cast<int (*)()>(dlsym(helper,"abc_sample_runtime_close"));
  auto metadata = reinterpret_cast<const char *(*)()>(dlsym(helper,"abc_sample_runtime_metadata_json"));
  if (!initialize || !capture || !close || !metadata) return 12;
  const int init = initialize();
  puts(metadata()); fflush(stdout);
  const char *action = argc > 1 ? argv[1] : "success";
  if (!strcmp(action,"dirty-after-init")) setenv("HEAPPROFILE", "forbidden", 1);
  if (!strcmp(action,"unowned-after-init")) setenv("ABC_STUB_SCENARIO", "unowned", 1);
  if (!strcmp(action,"output-mode-after-init")) chmod(getenv("ABC_SAMPLED_OUTPUT"), 0755);
  if (!strcmp(action,"library-change-after-init")) {
    FILE *file = fopen(getenv("LD_PRELOAD"), "ab");
    if (!file || fputc('x', file) == EOF || fclose(file)) return 13;
  }
  int cut = -1;
  if (!init) cut = capture(2000000);
  const int closed = close();
  puts(metadata()); fflush(stdout);
  if (!strcmp(action,"repeat")) {
    int repeat = capture(2000000), reinit = initialize(), reclose = close();
    printf("{\"repeat\":%d,\"reinitialize\":%d,\"reclose\":%d}\n", repeat, reinit, reclose);
    puts(metadata());
  }
  printf("{\"offline\":true,\"officialRuntimeInvoked\":false,\"initStatus\":%d,\"cutStatus\":%d,\"closeStatus\":%d}\n",init,cut,closed);
  return 0;
}
