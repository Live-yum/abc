/* Independent sampled q0 adapter. No constructors, background work, implicit
 * capture, full-profiler APIs, private symbols, or virtual-table inspection.
 * The normal public C++ API is linked against the matching official library.
 * Offline tests instead link an explicitly synthetic provider DSO. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "sample_runtime.h"
#include "sample_wrapper.h"
#include "native_identity.h"
#ifndef ABC_SAMPLE_SEALED_CONFIG
#error "An explicit audited sampled-only seal header is required"
#endif
#include ABC_SAMPLE_SEALED_CONFIG
#include <gperftools/malloc_extension.h>
#include <dlfcn.h>
#include <inttypes.h>
#include <time.h>

extern char **environ;
namespace {
struct Runtime {
  int target = -1, library = -1, output = -1;
  unsigned init_calls = 0, q0_calls = 0, close_calls = 0;
  bool initialized = false, closed = false, q0_accepted = false;
  int initialization_status = ABC_SAMPLE_RUNTIME_INIT, failure = 0;
  unsigned fd_opened = 0, fd_close_attempts = 0, fd_closed = 0, held_fds = 0;
  int cleanup_errno = 0, io_errno = 0;
  unsigned provider_checks = 0;
  bool instance_address_checked = false, ownership_checked = false;
  void *symbols[5] = {}, *provider_base = nullptr, *owned_byte = nullptr;
  MallocExtension *provider = nullptr;
  uint64_t gauge_us = 0, enter_ns = 0, ack_end_ns = 0, exit_ns = 0;
  size_t before_size = 0, after_size = 0;
  bool before_complete = false, after_complete = false;
  bool before_written = false, after_written = false;
  bool receipt_published = false, ack_accepted = false;
  abc_sample_context sample = {};
  char before[ABC_SAMPLE_MAP_CAP] = {}, after[ABC_SAMPLE_MAP_CAP] = {};
  char metadata[ABC_SAMPLE_METADATA_CAP] = {};
} runtime;

bool same_env(const char *name, const char *expected) {
  const char *value = getenv(name);
  return value && !strcmp(value, expected);
}
int fail(int status) {
  if (!runtime.failure) runtime.failure = status;
  return status;
}
int acquired(int fd) {
  if (fd >= 0) { ++runtime.fd_opened; ++runtime.held_fds; }
  return fd;
}
int close_fd(int &fd) {
  if (fd < 0) return 0;
  const int value = fd;
  fd = -1; // Never retry a possibly reused descriptor number, including EINTR.
  ++runtime.fd_close_attempts;
  --runtime.held_fds;
  if (close(value)) {
    if (!runtime.cleanup_errno) runtime.cleanup_errno = errno ? errno : EIO;
    return -1;
  }
  ++runtime.fd_closed;
  return 0;
}
void release_files() {
  close_fd(runtime.target); close_fd(runtime.library); close_fd(runtime.output);
}
uint64_t clock_ns() {
  timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) || now.tv_sec < 0 ||
      now.tv_nsec < 0 || now.tv_nsec >= 1000000000L) return 0;
  const uint64_t seconds = static_cast<uint64_t>(now.tv_sec);
  if (seconds > (UINT64_MAX - static_cast<uint64_t>(now.tv_nsec)) / UINT64_C(1000000000)) return 0;
  return seconds * UINT64_C(1000000000) + static_cast<uint64_t>(now.tv_nsec);
}
int within_hook() {
  const uint64_t now = clock_ns();
  if (!runtime.enter_ns || now < runtime.enter_ns) return ABC_SAMPLE_RUNTIME_CLOCK;
  return now - runtime.enter_ns >= ABC_SAMPLE_HOOK_NS ? ABC_SAMPLE_RUNTIME_TIMEOUT : 0;
}
bool same_stat(const struct stat &st, const abc_file_identity &id) {
  return S_ISREG(st.st_mode) && st.st_size >= 0 &&
    static_cast<uint64_t>(st.st_dev) == id.device &&
    static_cast<uint64_t>(st.st_ino) == id.inode &&
    static_cast<uint64_t>(st.st_size) == id.size;
}
/* Retained-FD bytes and current canonical pathname identity are checked. These
 * bounded observations do not freeze mappings or make pathname races atomic. */
bool retained_matches(int fd, const abc_file_identity &id) {
  struct stat before, after, path;
  char digest[65];
  return fd >= 0 && abc_canonical(id.path) && !fstat(fd, &before) && same_stat(before, id) &&
    !stat(id.path, &path) && same_stat(path, id) && !abc_sha_fd(fd, digest) &&
    !strcmp(digest, id.sha256) && !fstat(fd, &after) && same_stat(after, id) &&
    before.st_mtim.tv_sec == after.st_mtim.tv_sec && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec &&
    before.st_ctim.tv_sec == after.st_ctim.tv_sec && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec;
}
int open_file(const abc_file_identity &id, bool executable) {
  if (!id.sha256 || strlen(id.sha256) != 64 || id.size > 64u * 1024u * 1024u ||
      !abc_canonical(id.path)) return -1;
  int fd = acquired(open(id.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) || (executable && !(st.st_mode & 0111)) || !retained_matches(fd, id)) {
    close_fd(fd); return -1;
  }
  return fd;
}
bool output_matches() {
  struct stat fd, path;
  const abc_arm_identity &id = abc_sample_sealed_output;
  return runtime.output >= 0 && abc_canonical(id.output) && !fstat(runtime.output, &fd) &&
    S_ISDIR(fd.st_mode) && fd.st_uid == geteuid() && (fd.st_mode & 07777) == 0700 &&
    static_cast<uint64_t>(fd.st_dev) == id.device && static_cast<uint64_t>(fd.st_ino) == id.inode &&
    !stat(id.output, &path) && path.st_dev == fd.st_dev && path.st_ino == fd.st_ino;
}
bool target_matches() {
  struct stat actual;
  return retained_matches(runtime.target, abc_sample_sealed_target) &&
    !stat("/proc/self/exe", &actual) && same_stat(actual, abc_sample_sealed_target);
}
bool library_address(void *address) {
  Dl_info info = {};
  struct stat current;
  return address && dladdr(address, &info) && info.dli_fname &&
    !strcmp(info.dli_fname, abc_sample_sealed_library.path) &&
    (!runtime.provider_base || info.dli_fbase == runtime.provider_base) &&
    !stat(info.dli_fname, &current) && same_stat(current, abc_sample_sealed_library);
}
void *current_symbol(unsigned index) {
  static const char *const names[] = {"malloc", "calloc", "realloc", "free"};
  if (index < 4) return dlsym(RTLD_DEFAULT, names[index]);
  // A compiler-resolved address of a PUBLIC static method, never a guessed
  // mangled spelling or an extracted virtual function pointer.
  return reinterpret_cast<void *>(&MallocExtension::instance);
}
int provider_matches(void *) {
  ++runtime.provider_checks;
  if (!target_matches() || !retained_matches(runtime.library, abc_sample_sealed_library) ||
      !output_matches()) return 0;
  for (unsigned i = 0; i < 5; ++i) {
    void *actual = current_symbol(i);
    if (actual != runtime.symbols[i] || !library_address(actual)) return 0;
  }
  runtime.instance_address_checked = true;
  MallocExtension *current = MallocExtension::instance();
  if (!current || current != runtime.provider || !runtime.owned_byte ||
      current->GetOwnership(runtime.owned_byte) != MallocExtension::kOwned) return 0;
  runtime.ownership_checked = true;
  return 1;
}
int read_maps(char *buffer, size_t *length, bool *complete) {
  *length = 0; *complete = false;
  int fd = acquired(open("/proc/self/maps", O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (fd < 0) { runtime.io_errno = errno; return -1; }
  int status = 0;
  while (*length < ABC_SAMPLE_MAP_CAP) {
    ssize_t n = read(fd, buffer + *length, ABC_SAMPLE_MAP_CAP - *length);
    if (n < 0) { runtime.io_errno = errno; status = -1; break; }
    if (!n) break;
    *length += static_cast<size_t>(n);
  }
  char extra;
  const ssize_t n = status ? -1 : read(fd, &extra, 1);
  if (n != 0 || !*length || buffer[*length - 1] != '\n') status = -1;
  if (close_fd(fd)) status = -1;
  *complete = status == 0;
  return status;
}
int write_new(const char *name, const char *bytes, size_t length) {
  if (!output_matches() || length > ABC_SAMPLE_MAP_CAP) return -1;
  int fd = acquired(openat(runtime.output, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
  if (fd < 0) { runtime.io_errno = errno; return -1; }
  struct stat st;
  int status = 0;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
      (st.st_mode & 07777) != 0600 || st.st_nlink != 1 || st.st_size != 0) status = -1;
  if (!status) {
    const ssize_t n = write(fd, bytes, length); // No retry or truncation.
    if (n < 0 || static_cast<size_t>(n) != length) {
      runtime.io_errno = n < 0 ? errno : EIO; status = -1;
    } else if (fsync(fd)) { runtime.io_errno = errno; status = -1; }
  }
  if (close_fd(fd)) status = -1;
  return status;
}
/* Retain available bounded bytes on a failed cut too. Partial maps retain
 * their observed length but cannot receive a successful receipt. */
int retain_maps() {
  int result = 0;
  if (runtime.before_size && !runtime.before_written) {
    runtime.before_written = true;
    if (write_new(ABC_SAMPLE_BEFORE_NAME, runtime.before, runtime.before_size)) result = -1;
  }
  if (runtime.after_size && !runtime.after_written) {
    runtime.after_written = true;
    if (write_new(ABC_SAMPLE_AFTER_NAME, runtime.after, runtime.after_size)) result = -1;
  }
  return result;
}
int publish_receipt() {
  char receipt[ABC_SAMPLE_RECEIPT_CAP];
  const abc_sample_result &sample = runtime.sample.result;
  const int n = snprintf(receipt, sizeof receipt,
      "ABC_SAMPLED_RECEIPT_V1 0 0 %ld %" PRIu64 " %" PRIu64 " %zu %zu q0.sample.heap\n",
      static_cast<long>(getpid()), sample.api_start_ns, sample.api_end_ns,
      runtime.before_size, runtime.after_size);
  if (n <= 0 || n >= static_cast<int>(sizeof receipt) ||
      write_new("q0.sample.receipt.pending", receipt, static_cast<size_t>(n))) return -1;
  if (renameat2(runtime.output, "q0.sample.receipt.pending", runtime.output,
                ABC_SAMPLE_RECEIPT_NAME, RENAME_NOREPLACE)) { runtime.io_errno = errno; return -1; }
  runtime.receipt_published = true;
  if (fsync(runtime.output)) { runtime.io_errno = errno; return -1; }
  return 0;
}
int wait_ack() {
  const uint64_t now = clock_ns();
  if (!now || now > UINT64_MAX - ABC_SAMPLE_ACK_NS) return ABC_SAMPLE_RUNTIME_CLOCK;
  uint64_t deadline = now + ABC_SAMPLE_ACK_NS;
  const uint64_t hook_deadline = runtime.enter_ns + ABC_SAMPLE_HOOK_NS;
  if (hook_deadline < runtime.enter_ns) return ABC_SAMPLE_RUNTIME_CLOCK;
  if (deadline > hook_deadline) deadline = hook_deadline;
  static const char expected[] = "ABC_SAMPLED_ACK_V1 0 0 OK\n";
  for (;;) {
    const uint64_t current = clock_ns();
    if (!current || current < now) return ABC_SAMPLE_RUNTIME_CLOCK;
    if (current >= deadline) return ABC_SAMPLE_RUNTIME_ACK;
    int fd = acquired(openat(runtime.output, ABC_SAMPLE_ACK_NAME, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK));
    if (fd >= 0) {
      struct stat st;
      char data[ABC_SAMPLE_RECEIPT_CAP + 1];
      ssize_t n = -1;
      if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
          (st.st_mode & 07777) == 0600 && st.st_nlink == 1 && st.st_size == static_cast<off_t>(sizeof expected - 1))
        n = read(fd, data, sizeof data);
      const int closed = close_fd(fd);
      const uint64_t end = clock_ns();
      if (closed || n != static_cast<ssize_t>(sizeof expected - 1) ||
          memcmp(data, expected, sizeof expected - 1) || !end || end < current || end >= deadline)
        return ABC_SAMPLE_RUNTIME_ACK;
      runtime.ack_end_ns = end; runtime.ack_accepted = true;
      return 0;
    }
    if (errno != ENOENT) { runtime.io_errno = errno; return ABC_SAMPLE_RUNTIME_ACK; }
    // Preserve the original native ACK poll interval, separate from the
    // supervisor's existing 10ms poll. No new observer background thread.
    timespec delay = {0, 1000000};
    if (nanosleep(&delay, nullptr)) return ABC_SAMPLE_RUNTIME_ACK;
  }
}
bool launch_token_matches() {
  int fd = acquired(openat(runtime.output, "launch.once", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK));
  if (fd < 0) return false;
  char actual[128], expected[128];
  const int wanted = snprintf(expected, sizeof expected, "ABC_SAMPLED_LAUNCH_ONCE_V1 %ld sampled-q0\n", static_cast<long>(getpid()));
  struct stat st;
  ssize_t n = -1;
  if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
      (st.st_mode & 07777) == 0600 && st.st_nlink == 1 && st.st_size == wanted)
    n = read(fd, actual, sizeof actual);
  const int closed = close_fd(fd);
  return !closed && n == wanted && !memcmp(actual, expected, static_cast<size_t>(wanted));
}
bool environment_matches() {
  if (!same_env("ABC_SAMPLED_DIAGNOSTIC", "1") || !same_env("TCMALLOC_SAMPLE_PARAMETER", "524288") ||
      !same_env("LD_PRELOAD", abc_sample_sealed_library.path) ||
      !same_env("ABC_SAMPLED_HELPER", abc_sample_sealed_helper_path) ||
      !same_env("ABC_SAMPLED_OUTPUT", abc_sample_sealed_output.output)) return false;
  for (char **p = environ; p && *p; ++p) {
    if (!strncmp(*p, "HEAP", 4) || !strncmp(*p, "ABC_STACK_", 10) ||
        (!strncmp(*p, "LD_", 3) && strncmp(*p, "LD_PRELOAD=", 11)) ||
        (!strncmp(*p, "TCMALLOC", 8) && strncmp(*p, "TCMALLOC_SAMPLE_PARAMETER=", 25)) ||
        !strncmp(*p, "CPUPROFILE", 10) || !strncmp(*p, "MALLOC", 6)) return false;
  }
  return true;
}
bool cut_paths_unused() {
  static const char *const names[] = {
    ABC_SAMPLE_PENDING_NAME, ABC_SAMPLE_FINAL_NAME, ABC_SAMPLE_BEFORE_NAME,
    ABC_SAMPLE_AFTER_NAME, "q0.sample.receipt.pending", ABC_SAMPLE_RECEIPT_NAME,
    "q0.sample.ack.pending", ABC_SAMPLE_ACK_NAME
  };
  for (const char *name : names) {
    struct stat st;
    if (!fstatat(runtime.output, name, &st, AT_SYMLINK_NOFOLLOW) || errno != ENOENT) return false;
  }
  return true;
}
int initialize_impl() {
#ifndef ABC_SAMPLE_OFFLINE_TESTING
  if (strcmp(abc_sample_sealed_library.path, "/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16")) return ABC_SAMPLE_RUNTIME_INIT;
#endif
  if (!environment_matches()) return ABC_SAMPLE_RUNTIME_INIT;
  Dl_info helper = {};
  if (!dladdr(reinterpret_cast<void *>(&abc_sample_runtime_initialize), &helper) || !helper.dli_fname ||
      strcmp(helper.dli_fname, abc_sample_sealed_helper_path)) return ABC_SAMPLE_RUNTIME_INIT;
  runtime.target = open_file(abc_sample_sealed_target, true);
  if (runtime.target < 0) return ABC_SAMPLE_RUNTIME_INIT;
  runtime.library = open_file(abc_sample_sealed_library, false);
  if (runtime.library < 0) return ABC_SAMPLE_RUNTIME_INIT;
  if (!abc_canonical(abc_sample_sealed_output.output)) return ABC_SAMPLE_RUNTIME_INIT;
  runtime.output = acquired(open(abc_sample_sealed_output.output, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
  if (runtime.output < 0 || !output_matches() || !target_matches() ||
      !launch_token_matches() || !cut_paths_unused()) return ABC_SAMPLE_RUNTIME_INIT;
  for (unsigned i = 0; i < 5; ++i) {
    runtime.symbols[i] = current_symbol(i);
    if (!library_address(runtime.symbols[i])) return ABC_SAMPLE_RUNTIME_PROVIDER;
    if (!i) { Dl_info info = {}; dladdr(runtime.symbols[i], &info); runtime.provider_base = info.dli_fbase; }
  }
  runtime.provider = MallocExtension::instance();
  if (!runtime.provider) return ABC_SAMPLE_RUNTIME_PROVIDER;
  auto allocate = reinterpret_cast<void *(*)(size_t)>(runtime.symbols[0]);
  runtime.owned_byte = allocate(1);
  if (!runtime.owned_byte || !provider_matches(nullptr)) return ABC_SAMPLE_RUNTIME_PROVIDER;
  const abc_sample_config config = {ABC_SAMPLE_ABI, runtime.output,
    abc_sample_sealed_output.device, abc_sample_sealed_output.inode, nullptr, provider_matches};
  return abc_sample_initialize(&runtime.sample, &config);
}
int capture_impl() {
  runtime.enter_ns = clock_ns();
  if (!runtime.enter_ns) return ABC_SAMPLE_RUNTIME_CLOCK;
  if (!environment_matches() || !provider_matches(nullptr)) return ABC_SAMPLE_RUNTIME_PROVIDER;
  if (!cut_paths_unused()) return ABC_SAMPLE_RUNTIME_IO;
  if (read_maps(runtime.before, &runtime.before_size, &runtime.before_complete)) return ABC_SAMPLE_RUNTIME_MAPS;
  int status = within_hook();
  if (status) return status;
  status = abc_sample_capture_q0(&runtime.sample, 0);
  // Read the after snapshot even if sample transport failed, while retaining
  // the first failure. There is no second sample attempt and no truncation.
  const int maps_status = read_maps(runtime.after, &runtime.after_size, &runtime.after_complete);
  if (status) return status;
  if (maps_status) return ABC_SAMPLE_RUNTIME_MAPS;
  if (!provider_matches(nullptr)) return ABC_SAMPLE_RUNTIME_PROVIDER;
  if (retain_maps()) return ABC_SAMPLE_RUNTIME_IO;
  if ((status = within_hook())) return status;
  if (publish_receipt()) return ABC_SAMPLE_RUNTIME_IO;
  if ((status = within_hook())) return status;
  if ((status = wait_ack())) return status;
  return within_hook();
}
const char *boolean(bool value) { return value ? "true" : "false"; }
} // namespace

extern "C" int abc_sample_runtime_initialize(void) {
  ++runtime.init_calls;
  if (runtime.init_calls != 1) return ABC_SAMPLE_RUNTIME_CONSUMED;
  if (runtime.closed) return ABC_SAMPLE_RUNTIME_CLOSED;
  int status;
  try { status = initialize_impl(); } catch (...) { status = ABC_SAMPLE_RUNTIME_EXCEPTION; }
  runtime.initialization_status = status;
  runtime.initialized = status == 0;
  if (status) { fail(status); abc_sample_runtime_close(); }
  return status;
}
extern "C" int abc_sample_runtime_q0(uint64_t gauge_dart_us) {
  ++runtime.q0_calls;
  if (runtime.q0_calls != 1) return ABC_SAMPLE_RUNTIME_CONSUMED;
  if (!runtime.initialized) return fail(ABC_SAMPLE_RUNTIME_INIT);
  if (runtime.closed) return fail(ABC_SAMPLE_RUNTIME_CLOSED);
  runtime.gauge_us = gauge_dart_us;
  int status;
  try { status = capture_impl(); } catch (...) { status = ABC_SAMPLE_RUNTIME_EXCEPTION; }
  if (retain_maps() && !status) status = ABC_SAMPLE_RUNTIME_IO;
  runtime.exit_ns = clock_ns();
  if (!status) status = within_hook();
  runtime.q0_accepted = status == 0;
  return status ? fail(status) : 0;
}
extern "C" int abc_sample_runtime_close(void) {
  ++runtime.close_calls;
  if (runtime.closed) return runtime.cleanup_errno ? ABC_SAMPLE_RUNTIME_IO : 0;
  runtime.closed = true;
  if (runtime.owned_byte) {
    void *owned = runtime.owned_byte; runtime.owned_byte = nullptr;
    auto release = reinterpret_cast<void (*)(void *)>(runtime.symbols[3]);
    if (release) release(owned);
  }
  release_files();
  return runtime.cleanup_errno ? fail(ABC_SAMPLE_RUNTIME_IO) : 0;
}
extern "C" const char *abc_sample_runtime_metadata_json(void) {
  const abc_sample_result &s = runtime.sample.result;
  // Seal builder restricts paths to printable ASCII; JSON escaping is added
  // below by the builder path restriction (quotes/backslashes are forbidden).
  const int n = snprintf(runtime.metadata, sizeof runtime.metadata,
    "{\"schema\":\"abc.gperftools-sampled-runtime.v1\",\"abi\":1,\"mode\":\"sampled\",\"pid\":%ld,"
    "\"initialized\":%s,\"initializationStatus\":%d,\"q0Calls\":%u,\"closeCalls\":%u,\"closed\":%s,\"failure\":%d,\"q0TransportAccepted\":%s,"
    "\"estimationOnly\":true,\"transportOnly\":true,\"mapsAccepted\":false,\"fullRunCompleted\":false,"
    "\"provider\":{\"path\":\"%s\",\"sha256\":\"%s\",\"device\":%" PRIu64 ",\"inode\":%" PRIu64 ",\"publicInstanceAddressChecked\":%s,\"allocationOwnershipChecked\":%s,\"checks\":%u},"
    "\"target\":{\"path\":\"%s\",\"sha256\":\"%s\",\"device\":%" PRIu64 ",\"inode\":%" PRIu64 "},"
    "\"output\":{\"path\":\"%s\",\"device\":%" PRIu64 ",\"inode\":%" PRIu64 "},"
    "\"observer\":{\"fdOpened\":%u,\"fdCloseAttempts\":%u,\"fdClosed\":%u,\"heldFds\":%u,\"cleanupErrno\":%d,\"ioErrno\":%d,\"preallocatedMapsBytes\":%u,\"preallocatedRuntimeBytes\":%zu,\"retainedOwnershipProbeBytes\":1},"
    "\"cut\":{\"gaugeDartUs\":%" PRIu64 ",\"enterNs\":%" PRIu64 ",\"ackEndNs\":%" PRIu64 ",\"exitNs\":%" PRIu64 ",\"beforeBytes\":%zu,\"afterBytes\":%zu,\"beforeComplete\":%s,\"afterComplete\":%s,\"receiptPublished\":%s,\"ackAccepted\":%s},"
    "\"sample\":{\"abi\":%u,\"status\":%d,\"accepted\":%d,\"api_calls\":%u,\"provider_checks\":%u,\"output_opened\":%u,\"output_close_attempts\":%u,\"output_closed\":%u,\"cleanup_errno\":%d,\"io_errno\":%d,\"published\":%d,\"api_returned\":%d,\"hook_start_ns\":%" PRIu64 ",\"api_start_ns\":%" PRIu64 ",\"api_end_ns\":%" PRIu64 ",\"api_elapsed_ns\":%" PRIu64 ",\"hook_end_ns\":%" PRIu64 ",\"returned_bytes\":%" PRIu64 ",\"returned_capacity_bytes\":%" PRIu64 ",\"written_bytes\":%" PRIu64 "}}",
    static_cast<long>(getpid()), boolean(runtime.initialized), runtime.initialization_status,
    runtime.q0_calls, runtime.close_calls, boolean(runtime.closed), runtime.failure, boolean(runtime.q0_accepted),
    abc_sample_sealed_library.path, abc_sample_sealed_library.sha256, abc_sample_sealed_library.device, abc_sample_sealed_library.inode,
    boolean(runtime.instance_address_checked), boolean(runtime.ownership_checked), runtime.provider_checks,
    abc_sample_sealed_target.path, abc_sample_sealed_target.sha256, abc_sample_sealed_target.device, abc_sample_sealed_target.inode,
    abc_sample_sealed_output.output, abc_sample_sealed_output.device, abc_sample_sealed_output.inode,
    runtime.fd_opened, runtime.fd_close_attempts, runtime.fd_closed, runtime.held_fds, runtime.cleanup_errno,
    runtime.io_errno, 2u * ABC_SAMPLE_MAP_CAP, sizeof runtime,
    runtime.gauge_us, runtime.enter_ns, runtime.ack_end_ns, runtime.exit_ns, runtime.before_size, runtime.after_size,
    boolean(runtime.before_complete), boolean(runtime.after_complete), boolean(runtime.receipt_published), boolean(runtime.ack_accepted),
    s.abi, s.status, s.accepted, s.api_calls, s.provider_checks, s.output_opened, s.output_close_attempts, s.output_closed,
    s.cleanup_errno, s.io_errno, s.published, s.api_returned, s.hook_start_ns, s.api_start_ns, s.api_end_ns,
    s.api_elapsed_ns, s.hook_end_ns, s.returned_bytes, s.returned_capacity_bytes, s.written_bytes);
  if (n <= 0 || n >= static_cast<int>(sizeof runtime.metadata))
    snprintf(runtime.metadata, sizeof runtime.metadata, "{\"schema\":\"abc.gperftools-sampled-runtime.v1\",\"abi\":1,\"failure\":104,\"metadataOverflow\":true}");
  return runtime.metadata;
}
