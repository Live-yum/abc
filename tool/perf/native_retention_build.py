#!/usr/bin/env python3
"""Build the observation helper with the installed system compiler, externally.

No Flutter invocation, world opening, dependency download or application launch
occurs. A tiny fresh C process checks only the helper/header ABI and reports its
own runtime libc identity; this is not the later Dart process's support status.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

HELPER_SOURCE = 'tool/perf/native_retention_probe.c'
HELPER_NAME = 'libabc_native_retention_probe.so'
COMMAND_SECONDS = 60
CONTRACT_SOURCE = r'''
#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
extern int abc_retention_initialize_v1(void);
extern int abc_retention_snapshot_v1(uint64_t *, size_t);
int main(void) {
  uint64_t w[16];
  int status = abc_retention_initialize_v1();
  if (abc_retention_snapshot_v1(w, 16) != status) return 11;
  int matched = 0;
#if __GLIBC_PREREQ(2, 33)
  const struct mallinfo2 m = mallinfo2();
  const size_t expected[] = {m.arena, m.ordblks, m.smblks, m.hblks, m.hblkhd,
      m.usmblks, m.fsmblks, m.uordblks, m.fordblks, m.keepcost};
  if (status == 0) {
    if (w[0] != 1 || w[2] != sizeof(size_t) || w[3] != sizeof(m)) return 12;
    for (size_t i = 0; i < 10; i++) if (w[6+i] != expected[i]) return 13;
    if (w[6] != w[13] + w[14]) return 14;
    matched = 1;
  }
  const size_t struct_bytes = sizeof(struct mallinfo2);
#else
  const size_t struct_bytes = 0;
#endif
  Dl_info info;
  void *symbol = dlsym(RTLD_DEFAULT, "gnu_get_libc_version");
  if (!symbol || !dladdr(symbol, &info)) return 15;
  printf("{\"runtimeLibcVersion\":\"%s\",\"headerGlibcMajor\":%d,"
         "\"headerGlibcMinor\":%d,\"sizeTBytes\":%zu,"
         "\"mallinfo2StructBytes\":%zu,\"helperStatus\":%d,"
         "\"abiContractMatched\":%s}\n",
         gnu_get_libc_version(), __GLIBC__, __GLIBC_MINOR__, sizeof(size_t),
         struct_bytes, status, matched ? "true" : "null");
  /* Separate path line avoids assuming a filesystem path is JSON-safe. */
  puts(info.dli_fname);
  return 0;
}
'''


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open('rb') as source:
        for data in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(data)
    return hasher.hexdigest()


def _compiler(value):
    candidate = value or shutil.which('cc') or shutil.which('clang')
    found = shutil.which(str(candidate)) if candidate else None
    if not found:
        raise ValueError('An existing system cc/clang compiler is required')
    resolved = Path(found).resolve()
    allowed = (resolved.is_relative_to('/usr/bin')
               or resolved.is_relative_to('/usr/lib/gcc')
               or any(parent.name.startswith('llvm-') and parent.parent == Path('/usr/lib')
                      for parent in resolved.parents))
    if not allowed or not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError('Use the installed distribution compiler under /usr/bin or /usr/lib')
    return resolved


def _dependencies(path):
    tokens = shlex.split(path.read_text().replace('\\\n', ''))
    if not tokens or not tokens[0].endswith(':'):
        raise ValueError('Unexpected compiler dependency manifest')
    return sorted(set(Path(token).resolve() for token in tokens[1:]))


def build(source, output, compiler=None):
    source = Path(source).resolve()
    output_arg = Path(output)
    if output_arg.is_symlink():
        raise ValueError('Build output must be a new ordinary directory')
    output = output_arg.resolve()
    if output == source or source in output.parents or output in source.parents:
        raise ValueError('Helper build must be outside the entire application checkout')
    if output.exists():
        raise ValueError('Use a new helper build directory; never replace evidence')
    helper_source = source / HELPER_SOURCE
    if (helper_source.is_symlink() or not helper_source.is_file()
            or any(parent.is_symlink() for parent in helper_source.parents if parent != source)):
        raise ValueError('An ordinary native_retention_probe.c source is required')
    source_hash = digest(helper_source)
    compiler_path = _compiler(compiler)
    output.mkdir(parents=True)
    helper = output / HELPER_NAME
    contract_source = output / 'native-retention-build-contract.c'
    contract_binary = output / 'native-retention-build-contract'
    dependency_path = output / 'helper.d'
    result = {
        'schema': 'abc.native-retention-helper-build.v1', 'status': 'building',
        'helperPath': str(helper), 'helperFile': HELPER_NAME,
        'source': {'path': HELPER_SOURCE, 'sha256': source_hash},
        'compiler': {'path': str(compiler_path), 'sha256': digest(compiler_path)},
        'commands': [], 'headers': {}, 'runtime': None,
        'outsideApplicationCheckout': True, 'applicationLaunched': False,
        'downloadedDependencies': False,
    }
    # A fixed child-process environment prevents hidden compiler search paths,
    # injected allocator tunables or inherited loader overrides. Nothing is
    # exported into the application, and no environment contents are recorded.
    child_env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'TMPDIR': str(output)}

    def command(name, argv, *, required=True):
        stdout = output / (name + '.stdout.txt')
        stderr = output / (name + '.stderr.txt')
        record = {'name': name, 'argv': [str(x) for x in argv],
                  'timeoutSeconds': COMMAND_SECONDS,
                  'stdoutFile': stdout.name, 'stderrFile': stderr.name}
        result['commands'].append(record)
        try:
            with stdout.open('xb') as out, stderr.open('xb') as err:
                completed = subprocess.run(record['argv'], cwd=output, env=child_env,
                                           stdout=out, stderr=err, timeout=COMMAND_SECONDS,
                                           check=False)
            record['returnCode'] = completed.returncode
        except subprocess.TimeoutExpired:
            record['returnCode'] = None
            record['timedOut'] = True
            raise
        finally:
            record['stdoutSha256'] = digest(stdout)
            record['stderrSha256'] = digest(stderr)
        if required and record['returnCode'] != 0:
            raise ValueError('Helper build command failed: ' + name)
        return stdout.read_text(encoding='utf-8', errors='replace').strip(), record['returnCode']

    def package_identity(name, paths):
        tool = Path('/usr/bin/dpkg-query')
        if not tool.is_file():
            return {'status': 'unavailable', 'reason': 'dpkg-query-unavailable'}
        owners, status = command('package-' + name + '-owners',
                                 [tool, '-S', *[str(path) for path in paths]], required=False)
        packages = sorted({row.rsplit(': ', 1)[0] for row in owners.splitlines() if ': ' in row})
        if not packages:
            return {'status': 'unavailable', 'reason': 'package-ownership-unavailable',
                    'ownerQueryReturnCode': status, 'ownerOutput': owners,
                    'queriedPaths': [str(path) for path in paths]}
        owner_status = status
        metadata, status = command('package-' + name + '-versions',
                                   [tool, '-W', '-f=${binary:Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n',
                                    *packages], required=False)
        return {'status': 'available' if status == 0 else 'unavailable',
                'packages': packages, 'metadata': metadata, 'queryReturnCode': status,
                'ownerQueryReturnCode': owner_status,
                'queriedPaths': [str(path) for path in paths]}

    try:
        version, _ = command('compiler-version', [compiler_path, '--version'])
        target, _ = command('compiler-target', [compiler_path, '-dumpmachine'])
        result['compiler'].update({'version': version, 'target': target})
        result['compiler']['package'] = package_identity('compiler', [compiler_path])
        flags = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror']
        helper_command = [compiler_path, *flags, '-fPIC', '-fvisibility=hidden', '-shared',
                          '-MD', '-MF', dependency_path, helper_source, '-ldl', '-pthread',
                          '-o', helper]
        result['helperCommand'] = [str(x) for x in helper_command]
        command('compile-helper', helper_command)
        headers = {str(path): {'sha256': digest(path), 'bytes': path.stat().st_size}
                   for path in _dependencies(dependency_path) if path != helper_source}
        malloc_headers = [name for name in headers if Path(name).name == 'malloc.h']
        if len(malloc_headers) != 1:
            raise ValueError('Exactly one actual official malloc.h dependency is required')
        result['headers'] = headers
        result['dependencyFile'] = dependency_path.name
        result['dependencySha256'] = digest(dependency_path)
        result['mallocHeader'] = {'path': malloc_headers[0], **headers[malloc_headers[0]]}
        result['mallocHeader']['package'] = package_identity('headers', [malloc_headers[0]])
        contract_source.write_text(CONTRACT_SOURCE, encoding='utf-8')
        command('compile-build-contract', [compiler_path, *flags, contract_source, helper,
                                            '-ldl', '-o', contract_binary])
        stdout, _ = command('run-build-contract', [contract_binary])
        lines = stdout.splitlines()
        if len(lines) != 2:
            raise ValueError('Unexpected fresh-C-process ABI evidence')
        runtime = json.loads(lines[0])
        observed_libc = Path(lines[1])
        runtime_libc = observed_libc.resolve()
        if (not isinstance(runtime, dict) or not runtime_libc.is_file()
                or runtime['sizeTBytes'] not in (4, 8)
                or runtime['helperStatus'] not in range(5)
                or runtime['mallinfo2StructBytes'] not in (0, 10 * runtime['sizeTBytes'])
                or (runtime['helperStatus'] == 0 and runtime['abiContractMatched'] is not True)):
            raise ValueError('Invalid helper/header/runtime contract evidence')
        runtime.update({
            'scope': 'fresh-native-build-contract-process-only',
            'libcPath': str(runtime_libc), 'libcSha256': digest(runtime_libc),
            'package': package_identity('runtime-libc', sorted({runtime_libc, observed_libc})),
            'inspectedUpstreamFamily': runtime['runtimeLibcVersion'] in ('2.39', '2.41'),
            'sourceReviewRequired': runtime['runtimeLibcVersion'] not in ('2.39', '2.41'),
        })
        result['runtime'] = runtime
        result['buildContract'] = {
            'sourceFile': contract_source.name, 'sourceSha256': digest(contract_source),
            'executableFile': contract_binary.name, 'executableSha256': digest(contract_binary),
        }
        if digest(helper_source) != source_hash or digest(compiler_path) != result['compiler']['sha256']:
            raise ValueError('Source or compiler changed during helper build')
        if any(digest(name) != value['sha256'] for name, value in headers.items()):
            raise ValueError('System headers changed during helper build')
        result['helperSha256'] = digest(helper)
        result['helperBytes'] = helper.stat().st_size
        result['status'] = 'built'
    except BaseException as error:
        result['status'] = 'failed'
        result['failureType'] = type(error).__name__
        raise
    finally:
        with (output / 'helper-build.json').open('x', encoding='utf-8') as evidence:
            evidence.write(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--compiler')
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.output, args.compiler), indent=2))


if __name__ == '__main__':
    main()
