/* Compile against the matching official development header and link normally
 * against that exact official libtcmalloc in a separately authorized adapter.
 * No guessed mangled names, private allocator entrypoints, or full profiler.
 * Offline tests substitute only a test header/provider, never the official
 * library. There is intentionally no target/CI/Flutter integration here. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "sample_wrapper.h"
#include <gperftools/malloc_extension.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

namespace {
int environment_status() {
  const char *enabled = std::getenv(ABC_SAMPLE_ENABLE_ENV);
  if (!enabled || std::strcmp(enabled, "1") != 0) return ABC_SAMPLE_DISABLED;
  const char *parameter = std::getenv("TCMALLOC_SAMPLE_PARAMETER");
  if (!parameter || std::strcmp(parameter, "524288") != 0)
    return ABC_SAMPLE_BAD_ENV;
  /* Even zero-valued full-profiler controls are not inherited into this
   * independent mode. Never repair or rewrite the process environment. */
  for (char **entry = environ; entry && *entry; ++entry) {
    if (std::strncmp(*entry, "HEAP", 4) == 0) return ABC_SAMPLE_BAD_ENV;
  }
  return ABC_SAMPLE_OK;
}

bool directory_matches(const abc_sample_config &config) {
  struct stat st;
  return config.output_directory_fd >= 0 &&
         fstat(config.output_directory_fd, &st) == 0 && S_ISDIR(st.st_mode) &&
         st.st_uid == geteuid() && (st.st_mode & 07777) == 0700 &&
         static_cast<uint64_t>(st.st_dev) == config.output_device &&
         static_cast<uint64_t>(st.st_ino) == config.output_inode;
}

bool monotonic_ns(uint64_t *out) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
      now.tv_nsec < 0 || now.tv_nsec >= 1000000000L) return false;
  const uint64_t seconds = static_cast<uint64_t>(now.tv_sec);
  if (seconds > (UINT64_MAX - static_cast<uint64_t>(now.tv_nsec)) /
                    UINT64_C(1000000000)) return false;
  *out = seconds * UINT64_C(1000000000) + static_cast<uint64_t>(now.tv_nsec);
  return *out != 0;
}

int provider_matches(abc_sample_context *context) {
  ++context->result.provider_checks;
  return context->config.provider_matches(context->config.provider_guard_user)
             == 1 ? ABC_SAMPLE_OK : ABC_SAMPLE_PROVIDER;
}

int finish(abc_sample_context *context, int status) {
  abc_sample_result &result = context->result;
  uint64_t now = 0;
  if (!monotonic_ns(&now) || now < result.hook_start_ns) {
    if (status == ABC_SAMPLE_OK) status = ABC_SAMPLE_CLOCK;
  } else {
    result.hook_end_ns = now;
    if (status == ABC_SAMPLE_OK &&
        now - result.hook_start_ns > ABC_SAMPLE_HOOK_NS)
      status = ABC_SAMPLE_TIMEOUT;
  }
  result.status = status;
  result.accepted = status == ABC_SAMPLE_OK;
  return status;
}

/* Never retry close, including EINTR: the descriptor may already be closed
 * and another thread could have reused its number. Preserve the first error. */
int close_output(int fd, abc_sample_result *result, int primary) {
  ++result->output_close_attempts;
  if (close(fd) == 0) {
    ++result->output_closed;
  } else {
    result->cleanup_errno = errno;
    if (primary == ABC_SAMPLE_OK) primary = ABC_SAMPLE_CLOSE;
  }
  return primary;
}

int write_sample(abc_sample_context *context, const std::string &sample) {
  abc_sample_result &result = context->result;
  const abc_sample_config &config = context->config;
  if (!directory_matches(config)) return ABC_SAMPLE_OUTPUT;
  const int fd = openat(config.output_directory_fd, ABC_SAMPLE_PENDING_NAME,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        0600);
  if (fd < 0) { result.io_errno = errno; return ABC_SAMPLE_OUTPUT; }
  ++result.output_opened;
  int status = ABC_SAMPLE_OK;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
      (st.st_mode & 07777) != 0600 || st.st_nlink != 1 || st.st_size != 0) {
    result.io_errno = errno;
    status = ABC_SAMPLE_OUTPUT;
  } else {
    /* One bounded write. A short write or EINTR fails; no truncation/retry. */
    const ssize_t written = write(fd, sample.data(), sample.size());
    if (written > 0) result.written_bytes = static_cast<uint64_t>(written);
    if (written < 0 || static_cast<size_t>(written) != sample.size()) {
      result.io_errno = written < 0 ? errno : EIO;
      status = ABC_SAMPLE_WRITE;
    } else if (fstat(fd, &st) != 0 || st.st_size < 0 ||
               static_cast<uint64_t>(st.st_size) != result.returned_bytes ||
               st.st_nlink != 1 || !S_ISREG(st.st_mode)) {
      result.io_errno = errno;
      status = ABC_SAMPLE_OUTPUT;
    } else if (fsync(fd) != 0) {
      result.io_errno = errno;
      status = ABC_SAMPLE_SYNC;
    }
  }
  status = close_output(fd, &result, status);
  if (status != ABC_SAMPLE_OK) return status;
  if (!directory_matches(config)) return ABC_SAMPLE_OUTPUT;
  uint64_t now = 0;
  if (!monotonic_ns(&now) || now < result.hook_start_ns) return ABC_SAMPLE_CLOCK;
  if (now - result.hook_start_ns > ABC_SAMPLE_HOOK_NS) return ABC_SAMPLE_TIMEOUT;
  /* A fully written, synced and closed file only becomes the final artifact
   * atomically. Failed pending files remain evidence and are never reused. */
  if (renameat2(config.output_directory_fd, ABC_SAMPLE_PENDING_NAME,
                config.output_directory_fd, ABC_SAMPLE_FINAL_NAME,
                RENAME_NOREPLACE) != 0) {
    result.io_errno = errno;
    return ABC_SAMPLE_PUBLISH;
  }
  result.published = 1;
  return ABC_SAMPLE_OK;
}

int capture_sample(abc_sample_context *context) {
  abc_sample_result &result = context->result;
  const int before = provider_matches(context);
  if (before != ABC_SAMPLE_OK) return before;
  if (!directory_matches(context->config)) return ABC_SAMPLE_OUTPUT;
  MallocExtension *provider = MallocExtension::instance();
  if (!provider) return ABC_SAMPLE_PROVIDER;
  /* A NEW EMPTY string for each single allowed call. GetHeapSample appends
   * to its writer. Never reserve/cap/truncate or retain its data pointer. */
  std::string sample;
  if (!monotonic_ns(&result.api_start_ns) ||
      result.api_start_ns < result.hook_start_ns) return ABC_SAMPLE_CLOCK;
  int status = ABC_SAMPLE_OK;
  ++result.api_calls;
  try {
    provider->GetHeapSample(&sample);
    result.api_returned = 1;
  } catch (const std::bad_alloc &) {
    status = ABC_SAMPLE_BAD_ALLOC;
  } catch (...) {
    status = ABC_SAMPLE_EXCEPTION;
  }
  result.returned_bytes = static_cast<uint64_t>(sample.size());
  result.returned_capacity_bytes = static_cast<uint64_t>(sample.capacity());
  if (!monotonic_ns(&result.api_end_ns) || result.api_end_ns < result.api_start_ns) {
    if (status == ABC_SAMPLE_OK) status = ABC_SAMPLE_CLOCK;
  } else {
    result.api_elapsed_ns = result.api_end_ns - result.api_start_ns;
    if (status == ABC_SAMPLE_OK &&
        result.api_end_ns - result.hook_start_ns > ABC_SAMPLE_HOOK_NS)
      status = ABC_SAMPLE_TIMEOUT;
  }
  if (status != ABC_SAMPLE_OK) return status;
  const int after = provider_matches(context);
  if (after != ABC_SAMPLE_OK) return after;
  if (sample.empty()) return ABC_SAMPLE_EMPTY;
  if (sample.size() >= ABC_SAMPLE_RAW_LIMIT) return ABC_SAMPLE_TOO_LARGE;
  return write_sample(context, sample);
  /* sample is destroyed here, before the caller records hook_end_ns. */
}
}  // namespace

extern "C" unsigned abc_sample_abi(void) { return ABC_SAMPLE_ABI; }

extern "C" int abc_sample_initialize(abc_sample_context *context,
                                      const abc_sample_config *config) {
  if (!context) return ABC_SAMPLE_BAD_INIT;
  if (context->initialized) return ABC_SAMPLE_ALREADY_ATTEMPTED;
  std::memset(context, 0, sizeof(*context));
  context->initialized = 1;
  context->result.abi = ABC_SAMPLE_ABI;
  int status = environment_status();
  if (status == ABC_SAMPLE_OK &&
      (!config || config->abi != ABC_SAMPLE_ABI || !config->provider_matches ||
       !directory_matches(*config))) status = ABC_SAMPLE_BAD_INIT;
  if (status == ABC_SAMPLE_OK) context->config = *config;
  context->result.status = status;
  return status;
}

extern "C" int abc_sample_capture_q0(abc_sample_context *context, int cycle) {
  if (!context || !context->initialized) return ABC_SAMPLE_BAD_INIT;
  if (context->consumed) return ABC_SAMPLE_ALREADY_ATTEMPTED;
  context->consumed = 1;
  abc_sample_result &result = context->result;
  if (result.status != ABC_SAMPLE_OK) return result.status;
  if (cycle != 0) { result.status = ABC_SAMPLE_WRONG_CUT; return result.status; }
  const int env_status = environment_status();
  if (env_status != ABC_SAMPLE_OK) { result.status = env_status; return env_status; }
  if (!monotonic_ns(&result.hook_start_ns)) {
    result.status = ABC_SAMPLE_CLOCK;
    return result.status;
  }
  try {
    return finish(context, capture_sample(context));
  } catch (const std::bad_alloc &) {
    return finish(context, ABC_SAMPLE_BAD_ALLOC);
  } catch (...) {
    return finish(context, ABC_SAMPLE_EXCEPTION);
  }
}
