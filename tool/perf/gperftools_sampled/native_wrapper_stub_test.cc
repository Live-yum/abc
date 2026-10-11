/* OFFLINE ONLY. Synthetic public-API-shaped provider; no official runtime. */
#include "sample_wrapper.h"
#include <gperftools/malloc_extension.h>
#include <cassert>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace {
const char *scenario;
unsigned instance_calls, sample_calls, guard_calls, clock_calls;
unsigned write_calls, close_calls, open_calls, sync_calls, publish_calls;
int output_fd = -1;
bool writer_was_empty = false;
bool is(const char *value) { return std::strcmp(scenario, value) == 0; }
const char fixture[] =
    "heap profile:      1:      64 [     1:      64] @ heap_v2/524288\n"
    "     1:       64 [     1:       64] @ 0x1001\n"
    "\nMAPPED_LIBRARIES:\n"
    "00001000-00002000 r-xp 00000000 00:00 1 /offline/synthetic-provider\n";

class StubProvider final : public MallocExtension {
 public:
  void GetHeapSample(std::string *writer) override {
    ++sample_calls;
    writer_was_empty = writer->empty();
    assert(writer_was_empty);
    if (is("exception")) throw std::runtime_error("synthetic provider error");
    if (is("bad-alloc")) throw std::bad_alloc();
    if (is("empty")) return;
    if (is("at-limit")) { writer->append(ABC_SAMPLE_RAW_LIMIT, 'x'); return; }
    if (is("over-limit")) { writer->append(ABC_SAMPLE_RAW_LIMIT + 7, 'x'); return; }
    if (is("under-limit")) { writer->append(ABC_SAMPLE_RAW_LIMIT - 1, 'x'); return; }
    writer->append(fixture);
    if (is("partial-exception")) throw std::runtime_error("partial synthetic data");
    if (is("nul")) writer->push_back('\0');
  }
} stub_provider;

int guard(void *) {
  ++guard_calls;
  if (is("provider-throw")) throw std::runtime_error("synthetic identity error");
  if (is("wrong-provider") || (is("provider-changed") && guard_calls > 1)) return 0;
  return 1;
}
}  // namespace

MallocExtension *MallocExtension::instance() {
  ++instance_calls;
  if (is("null-provider")) return nullptr;
  if (is("instance-throw")) throw std::runtime_error("synthetic instance error");
  return &stub_provider;
}

extern "C" int __real_openat(int, const char *, int, ...);
extern "C" ssize_t __real_write(int, const void *, size_t);
extern "C" int __real_close(int);
extern "C" int __real_fsync(int);
extern "C" int __real_renameat2(int, const char *, int, const char *, unsigned);

extern "C" int __wrap_openat(int dirfd, const char *path, int flags, ...) {
  va_list args;
  va_start(args, flags);
  const mode_t mode = static_cast<mode_t>(va_arg(args, int));
  va_end(args);
  ++open_calls;
  if (is("open-failure")) { errno = EACCES; return -1; }
  output_fd = __real_openat(dirfd, path, flags, mode);
  return output_fd;
}
extern "C" ssize_t __wrap_write(int fd, const void *bytes, size_t count) {
  if (fd == output_fd) {
    ++write_calls;
    if (is("short-write") || is("short-and-close"))
      return __real_write(fd, bytes, count / 2);
    if (is("write-eintr")) { errno = EINTR; return -1; }
    if (is("write-failure")) { errno = ENOSPC; return -1; }
  }
  return __real_write(fd, bytes, count);
}
extern "C" int __wrap_close(int fd) {
  if (fd == output_fd) {
    ++close_calls;
    output_fd = -1;
    const int result = __real_close(fd);
    if (is("close-failure") || is("short-and-close")) { errno = EINTR; return -1; }
    return result;
  }
  return __real_close(fd);
}
extern "C" int __wrap_fsync(int fd) {
  ++sync_calls;
  if (is("sync-failure")) { errno = EIO; return -1; }
  return __real_fsync(fd);
}
extern "C" int __wrap_renameat2(int olddir, const char *oldname,
                                 int newdir, const char *newname, unsigned flags) {
  ++publish_calls;
  if (is("publish-failure")) { errno = EIO; return -1; }
  return __real_renameat2(olddir, oldname, newdir, newname, flags);
}
extern "C" int __wrap_clock_gettime(clockid_t id, struct timespec *now) {
  assert(id == CLOCK_MONOTONIC);
  ++clock_calls;
  if (is("clock-failure") && clock_calls == 3) { errno = EIO; return -1; }
  uint64_t ns = UINT64_C(1000000000) + clock_calls * UINT64_C(1000000);
  if (is("zero-clock") && clock_calls == 1) ns = 0;
  if (is("backwards-clock") && clock_calls == 3) ns = UINT64_C(1000000000);
  if ((is("slow-api") && clock_calls >= 3) ||
      (is("slow-write") && clock_calls >= 4) ||
      (is("slow-finish") && clock_calls >= 5)) ns += ABC_SAMPLE_HOOK_NS;
  now->tv_sec = static_cast<time_t>(ns / UINT64_C(1000000000));
  now->tv_nsec = static_cast<long>(ns % UINT64_C(1000000000));
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  scenario = argv[1];
  const int directory = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (directory < 0) return 3;
  struct stat st;
  if (fstat(directory, &st) != 0) return 4;
  abc_sample_config config = {ABC_SAMPLE_ABI, directory,
      static_cast<uint64_t>(st.st_dev), static_cast<uint64_t>(st.st_ino), nullptr, guard};
  if (is("wrong-directory-identity")) ++config.output_inode;
  if (is("missing-guard")) config.provider_matches = nullptr;
  if (is("wrong-abi")) ++config.abi;
  abc_sample_context context = {};
  const char *parameter = std::getenv("TCMALLOC_SAMPLE_PARAMETER");
  const char *enabled = std::getenv(ABC_SAMPLE_ENABLE_ENV);
  const std::string env_before = std::string(parameter ? parameter : "<absent>") + ":" +
                                 (enabled ? enabled : "<absent>");
  const int initialized = abc_sample_initialize(&context, &config);
  if (is("directory-changed")) {
    if (fchmod(directory, 0755) != 0) return 5;
  }
  const int status = abc_sample_capture_q0(&context, is("wrong-cut") ? 7 : 0);
  const int repeated = abc_sample_capture_q0(&context, 0);
  const int reinitialized = abc_sample_initialize(&context, &config);
  const abc_sample_result &r = context.result;
  const std::string env_after = std::string(std::getenv("TCMALLOC_SAMPLE_PARAMETER") ?
      std::getenv("TCMALLOC_SAMPLE_PARAMETER") : "<absent>") + ":" +
      (std::getenv(ABC_SAMPLE_ENABLE_ENV) ? std::getenv(ABC_SAMPLE_ENABLE_ENV) : "<absent>");
  const int directory_still_open = fstat(directory, &st) == 0;
  std::printf("{\"offline\":true,\"officialRuntimeInvoked\":false,"
      "\"abi\":%u,\"initialized\":%d,\"status\":%d,\"recordedStatus\":%d,"
      "\"repeated\":%d,\"reinitialized\":%d,\"accepted\":%d,"
      "\"apiCalls\":%u,\"instanceCalls\":%u,\"sampleCalls\":%u,"
      "\"providerChecks\":%u,\"guardCalls\":%u,\"emptyWriter\":%d,"
      "\"apiReturned\":%d,\"returnedBytes\":%llu,\"capacityBytes\":%llu,"
      "\"writtenBytes\":%llu,\"hookStartNs\":%llu,\"apiStartNs\":%llu,"
      "\"apiEndNs\":%llu,\"apiElapsedNs\":%llu,\"hookEndNs\":%llu,"
      "\"openCalls\":%u,\"writeCalls\":%u,\"syncCalls\":%u,"
      "\"closeCalls\":%u,\"closeAttempts\":%u,\"closed\":%u,"
      "\"cleanupErrno\":%d,\"ioErrno\":%d,\"publishCalls\":%u,"
      "\"published\":%d,\"directoryStillOpen\":%d,\"envUnchanged\":%d}\n",
      abc_sample_abi(), initialized, status, r.status, repeated, reinitialized, r.accepted,
      r.api_calls, instance_calls, sample_calls, r.provider_checks, guard_calls,
      writer_was_empty, r.api_returned,
      static_cast<unsigned long long>(r.returned_bytes),
      static_cast<unsigned long long>(r.returned_capacity_bytes),
      static_cast<unsigned long long>(r.written_bytes),
      static_cast<unsigned long long>(r.hook_start_ns),
      static_cast<unsigned long long>(r.api_start_ns),
      static_cast<unsigned long long>(r.api_end_ns),
      static_cast<unsigned long long>(r.api_elapsed_ns),
      static_cast<unsigned long long>(r.hook_end_ns),
      open_calls, write_calls, sync_calls, close_calls, r.output_close_attempts,
      r.output_closed, r.cleanup_errno, r.io_errno, publish_calls, r.published,
      directory_still_open, env_before == env_after);
  __real_close(directory);
  return 0;
}
