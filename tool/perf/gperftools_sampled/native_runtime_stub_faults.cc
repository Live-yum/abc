/* OFFLINE TEST ONLY. Models Linux close(EINTR) after the FD was released.
 * It must never be linked into an official/provider build. */
#include <cerrno>
#include <cstdlib>
#include <cstring>
extern "C" int __real_close(int);
extern "C" int __wrap_close(int fd) {
  static bool injected = false;
  const int result = __real_close(fd);
  const char *scenario = getenv("ABC_STUB_SCENARIO");
  if (!injected && scenario && !strcmp(scenario, "close-eintr")) {
    injected = true;
    errno = EINTR;
    return -1;
  }
  return result;
}
