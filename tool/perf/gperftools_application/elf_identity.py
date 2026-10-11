"""Bound actual loaded ELF bytes, PT_LOAD ranges, build IDs and exact symbols.

No nearest-symbol attribution, debug downloading, process memory reads, or RSS
sampling. All identities come from retained regular-file FDs and target maps.
"""
from __future__ import annotations
import hashlib
import bisect
import os
from pathlib import Path
import stat
import struct
import time

from application_contract import (MAX_MAPS, MAX_MODULE, bounded_bytes, map_key,
    normalized_file_pc, parse_maps, require, validate_module_records)
from application_process import save


def need_time(deadline):
    require(time.monotonic() < deadline, 'ELF identity/shared deadline expired')


def stat_key(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def file_identity(path):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'Canonical regular path required')
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= MAX_MODULE,
                f'Sealed file exceeds 64 MiB/type cap: {path} ({before.st_size} bytes)')
        digest, length = hashlib.sha256(), 0
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            length += len(chunk)
            require(length <= MAX_MODULE, 'Sealed file grew beyond 64 MiB: ' + str(path))
            digest.update(chunk)
        require(stat_key(before) == stat_key(os.fstat(fd)) == stat_key(path.stat())
                and length == before.st_size, 'Sealed file changed while hashing: ' + str(path))
        return {'path': str(path), 'device': before.st_dev, 'inode': before.st_ino,
                'bytes': length, 'sha256': digest.hexdigest()}
    finally:
        os.close(fd)


def elf_metadata(data):
    """Strict little-endian ELF64/x86-64 parser for bounded preserved bytes."""
    require(len(data) >= 64 and data[:7] == b'\x7fELF\x02\x01\x01', 'Expected ELF64 little endian')
    header = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)
    kind, machine, version, _, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, shstr = header
    require(kind in (2, 3) and machine == 62 and version == 1 and ehsize == 64,
            'Unsupported ELF platform/type/header')
    require(phsize == 56 and 0 < phnum <= 256 and shsize == 64 and 0 < shnum <= 65535
            and shstr < shnum, 'Unsupported extended/absent ELF tables')

    def extent(offset, size):
        require(0 <= offset <= len(data) and 0 <= size <= len(data) - offset, 'ELF table extent')
        return data[offset:offset + size]

    extent(phoff, phnum * phsize)
    extent(shoff, shnum * shsize)
    loads, notes = [], []
    for i in range(phnum):
        ptype, flags, off, vaddr, _, filesz, memsz, align = struct.unpack_from('<IIQQQQQQ', data, phoff + i * 56)
        if ptype in (1, 4):
            extent(off, filesz)
        if ptype == 1:
            require(filesz <= memsz and align >= 4096 and align & (align - 1) == 0, 'ELF load alignment')
            loads.append(dict(offset=off, vaddr=vaddr, fileSize=filesz, memorySize=memsz, flags=flags, align=align))
        elif ptype == 4:
            notes.append(extent(off, filesz))
    build_ids = set()
    for note in notes:
        offset = 0
        while offset < len(note):
            require(len(note) - offset >= 12, 'Truncated ELF note')
            namesz, descsz, ntype = struct.unpack_from('<III', note, offset)
            offset += 12
            name_end, desc_start = offset + namesz, offset + ((namesz + 3) & ~3)
            end = desc_start + descsz
            require(name_end <= len(note) and end <= len(note), 'ELF note extent')
            if note[offset:name_end] == b'GNU\x00' and ntype == 3:
                require(4 <= descsz <= 64, 'ELF build ID extent')
                build_ids.add(note[desc_start:end].hex())
            offset = desc_start + ((descsz + 3) & ~3)
            require(offset <= len(note), 'ELF note padding extent')
    require(len(build_ids) == 1 and loads, 'Unique GNU build ID/PT_LOAD required')
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * 64) for i in range(shnum)]
    shnames = sections[shstr]
    require(shnames[1] == 3, 'ELF section-name table missing')
    section_names = extent(shnames[4], shnames[5])
    names = []
    for section in sections:
        start = section[0]
        require(start < len(section_names), 'ELF section-name extent')
        end = section_names.find(b'\x00', start)
        require(start <= end < start + 65536, 'ELF section-name terminator')
        names.append(section_names[start:end])
    symbols = {'dynsym': [], 'symtab': []}
    for section in sections:
        _, skind, _, _, off, size, link, _, _, entsize = section
        if skind not in (2, 11):
            continue
        require(entsize == 24 and size % 24 == 0 and size // 24 <= 262144 and link < len(sections),
                'ELF symbol table bounds')
        extent(off, size)
        strings = sections[link]
        require(strings[1] == 3, 'ELF symbol string table missing')
        string_data = extent(strings[4], strings[5])
        out = symbols['dynsym' if skind == 11 else 'symtab']
        for index in range(size // 24):
            name, info, _, shindex, value, length = struct.unpack_from('<IBBHQQ', data, off + index * 24)
            if shindex == 0 or info & 15 not in (2, 10) or not length:
                continue
            require(name < len(string_data), 'ELF symbol name extent')
            end = string_data.find(b'\x00', name)
            require(name <= end < name + 65536, 'ELF symbol name missing/oversized')
            text = string_data[name:end].decode('utf-8', errors='strict')
            require(value + length < 2**64, 'ELF symbol integer overflow')
            out.append({'name': text, 'address': value, 'size': length})
    return {'buildId': next(iter(build_ids)), 'ptLoad': loads, **symbols,
            'debugInfo': None, 'debugInfoPolicy': 'embedded-or-existing-build-id-matched-only; no downloads',
            'hasEmbeddedDebugInfo': b'.debug_info' in names or b'.zdebug_info' in names,
            'elfType': kind}


def load_bias(rows, metadata):
    candidates = None
    for row in rows:
        here = set()
        for seg in metadata['ptLoad']:
            if not seg['flags'] & 1:
                continue
            bias = row['start'] - row['offset'] - seg['vaddr'] + seg['offset']
            if bias >= 0 and bias + (seg['vaddr'] & ~4095) <= row['start'] < row['end'] <= bias + ((seg['vaddr'] + seg['memorySize'] + 4095) & ~4095):
                here.add(bias)
        candidates = here if candidates is None else candidates & here
    require(candidates is not None and len(candidates) == 1, 'Ambiguous/unbound ELF load bias')
    return next(iter(candidates))


def target_maps(identity):
    identity.verify()
    fd = os.open('maps', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=identity.proc_fd)
    try:
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(MAX_MAPS + 1)
        require(0 < len(data) <= MAX_MAPS, 'Startup target maps cap')
    finally:
        os.close(fd)
    identity.verify()
    return data, parse_maps(data)


class BoundModules:
    def __init__(self, identity, required, module_store, evidence, *, deadline, cap_check, presealed=None):
        self.identity, self.held, self.records, self.deferred = identity, {}, {}, {}
        self.transitions = []
        self.module_store = Path(module_store)
        self.module_store.mkdir(mode=0o700, parents=True, exist_ok=True)
        presealed = presealed or {}
        sealed = {**required, **presealed}
        try:
            data, maps = target_maps(identity)
            Path(evidence).mkdir(mode=0o700, parents=True, exist_ok=False)
            (Path(evidence) / 'startup.maps').write_bytes(data)
            rows = [row for row in maps if 'x' in row['permissions'] and row['path'].startswith('/')]
            paths = sorted({row['path'] for row in rows})
            require(0 < len(paths) <= 128 and set(required) <= set(paths),
                    'Required target/libapp/Flutter/helper/allocator modules not actually mapped')
            self.executable_keys = {map_key(row) for row in rows}
            for path in sorted(set(paths) | set(presealed)):
                row = self.capture_file(path, sealed.get(path), deadline, cap_check)
                mapped = [item for item in rows if item['path'] == path]
                if mapped:
                    self.bind_mappings(row, mapped)
                    row['loadedAtStartup'] = True
                    self.records[path] = row
                else:
                    row['loadedAtStartup'] = False
                    row['loadedIdentityProven'] = False
                    self.deferred[path] = row
                save(Path(evidence) / (row['sha256'] + '.json'), row, new=True)
                cap_check()
            validate_module_records({'fileExecutableMaps': sorted(self.executable_keys)}, self.records)
            self.verify_metadata()
            _, latest = target_maps(identity)
            require({map_key(row) for row in latest if 'x' in row['permissions'] and row['path'].startswith('/')} == self.executable_keys,
                    'Executable module maps changed during startup gate')
            need_time(deadline)
        except BaseException:
            self.close()
            raise

    def capture_file(self, path, expected, deadline, cap_check):
        need_time(deadline)
        require(str(Path(path).resolve()) == path, 'Loaded module path is not canonical')
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        self.held[path] = (fd, None)
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_MODULE,
                f'Module exceeds 64 MiB/type cap: {path} ({info.st_size} bytes)')
        self.held[path] = (fd, stat_key(info))
        chunks, digest, length = [], hashlib.sha256(), 0
        while True:
            need_time(deadline)
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk); digest.update(chunk); length += len(chunk)
            require(length <= MAX_MODULE, 'Module grew beyond cap')
        payload = b''.join(chunks)
        require(stat_key(os.fstat(fd)) == stat_key(info) and len(payload) == info.st_size,
                'Module changed during retention')
        row = dict(path=path, bytes=length, sha256=digest.hexdigest(), device=info.st_dev, inode=info.st_ino,
                   **elf_metadata(payload))
        if expected is not None:
            require({key: row[key] for key in ('path', 'device', 'inode', 'bytes', 'sha256')} == expected,
                    'Module differs from sealed artifact')
        stored = self.module_store / (row['sha256'] + '.elf')
        if stored.exists():
            require(hashlib.sha256(bounded_bytes(stored, MAX_MODULE)).hexdigest() == row['sha256'], 'Existing module store corruption')
        else:
            cap_check(extra_bytes=len(payload))
            with stored.open('xb') as stream:
                stream.write(payload)
        row['preservedElf'] = str(stored)
        if row['hasEmbeddedDebugInfo']:
            row['debugInfo'] = {'buildId': row['buildId'], 'sha256': row['sha256'],
                                'kind': 'embedded', 'preservedElf': str(stored)}
        else:
            # Ordinary installed build-ID debug location only; never download
            # or attribute an unmatched debug file. Missing symbols stay unknown.
            candidate = Path('/usr/lib/debug/.build-id') / row['buildId'][:2] / (row['buildId'][2:] + '.debug')
            if candidate.exists():
                need_time(deadline)
                debug_path = candidate.resolve()
                debug = file_identity(debug_path)
                payload = bounded_bytes(debug_path, MAX_MODULE)
                metadata = elf_metadata(payload)
                require(metadata['buildId'] == row['buildId'], 'Installed debug build ID does not match module')
                debug_stored = self.module_store / (debug['sha256'] + '.debug')
                if not debug_stored.exists():
                    cap_check(extra_bytes=len(payload))
                    with debug_stored.open('xb') as stream:
                        stream.write(payload)
                else:
                    require(hashlib.sha256(bounded_bytes(debug_stored, MAX_MODULE)).hexdigest() == debug['sha256'], 'Preserved debug bytes changed')
                row['debugInfo'] = {'buildId': row['buildId'], 'sha256': debug['sha256'],
                    'bytes': debug['bytes'], 'kind': 'existing-build-id-match',
                    'source': str(debug_path), 'preservedElf': str(debug_stored)}
                row['symtab'].extend(metadata['symtab'])
        return row

    @staticmethod
    def bind_mappings(row, mapped):
        require(mapped and all(item['inode'] == row['inode'] and item['device'] ==
                (os.major(row['device']), os.minor(row['device'])) for item in mapped),
                'Mapped module device/inode differs from sealed retained ELF')
        row['loadBias'] = load_bias(mapped, row)
        row['loadedIdentityProven'] = True

    def verify_metadata(self):
        for fd, expected in self.held.values():
            require(expected == stat_key(os.fstat(fd)), 'Retained module metadata changed')

    def verify_cut(self, bracket):
        self.verify_metadata()
        current = set(bracket['fileExecutableMaps'])
        require(self.executable_keys <= current,
                'Previously bound executable mapping disappeared/changed')
        extra = current - self.executable_keys
        extra_paths = {row[-1] for row in extra}
        require(extra_paths <= set(self.deferred),
                'New executable module was not presealed before ready')
        for path in sorted(extra_paths):
            row = dict(self.deferred[path])
            # This is the first proof that the presealed lazy engine is loaded.
            # No hashing, copying, dlopen, or new sampling is added to the ACK.
            mapped = [item for item in bracket['before'] if item['path'] == path and 'x' in item['permissions']]
            self.bind_mappings(row, mapped)
            validate_module_records({'fileExecutableMaps': sorted(item for item in current if item[-1] == path)}, {path: row})
            self.records[path] = row
            del self.deferred[path]
            self.transitions.append({'path': path, 'sha256': row['sha256'], 'buildId': row['buildId'],
                                     'loadBias': row['loadBias'], 'device': row['device'], 'inode': row['inode'],
                                     'loadedAtStartup': False, 'firstBoundAtEndpoint': True})
        self.executable_keys = current

    def rehash(self, deadline):
        for path, (fd, _) in self.held.items():
            os.lseek(fd, 0, os.SEEK_SET)
            digest = hashlib.sha256()
            while True:
                need_time(deadline)
                data = os.read(fd, 1 << 20)
                if not data:
                    break
                digest.update(data)
            row = self.records.get(path) or self.deferred[path]
            require(digest.hexdigest() == row['sha256'], 'Retained module bytes changed')
        self.verify_metadata()

    def close(self):
        for fd, _ in self.held.values():
            os.close(fd)
        self.held.clear()


def endpoint_delta(first, last, modules):
    """All buckets, including historical zero live rows, and explicit unknowns."""
    indices = {}
    for path, module in modules.items():
        symbols = sorted({(row['address'], row['address'] + row['size'], row['name'])
                          for kind in ('dynsym', 'symtab') for row in module[kind] if row['size']})
        starts, ends, peak = [], [], 0
        for start, end, _ in symbols:
            starts.append(start); peak = max(peak, end); ends.append(peak)
        indices[path] = symbols, starts, ends
    def exact_symbols(path, offset):
        symbols, starts, ends = indices[path]
        position = bisect.bisect_right(starts, offset) - 1
        names = set()
        while position >= 0 and ends[position] > offset:
            start, end, name = symbols[position]
            if start <= offset < end:
                names.add(name)
            position -= 1
        return sorted(names)
    def normalize(profile):
        result = {}
        for bucket in profile['buckets']:
            key, frames, unknown = [], [], False
            for pc in bucket['stack']:
                mapping = next(row for row in profile['maps'] if row['start'] <= pc < row['end'] and 'x' in row['permissions'])
                if mapping['path'] in modules:
                    build_id, offset = normalized_file_pc(pc, mapping, modules[mapping['path']])
                    key.append((build_id, offset))
                    names = exact_symbols(mapping['path'], offset)
                    unknown = unknown or not names
                    frames.append({'buildId': build_id, 'elfOffset': offset, 'exactRangeSymbolCandidates': names,
                                   'functionKnown': bool(names), 'module': mapping['path']})
                else:
                    unknown = True
                    key.append(('unknown:' + (mapping['path'] or 'anonymous'), pc))
                    frames.append({'pc': pc, 'mapping': mapping['path'], 'functionKnown': False})
            key = tuple(key)
            row = result.setdefault(key, {'counts': [0, 0, 0, 0], 'unknown': unknown, 'frames': frames})
            row['counts'] = [a + b for a, b in zip(row['counts'], bucket['counters'])]
        return result
    before, after = normalize(first), normalize(last)
    rows = []
    for key in sorted(before.keys() | after.keys()):
        a, b = before.get(key, {'counts': [0] * 4}), after.get(key, {'counts': [0] * 4})
        rows.append({'stack': key, 'frames': a.get('frames', b.get('frames')), 'q0': a['counts'], 'q7': b['counts'],
                     'delta': [y - x for x, y in zip(a['counts'], b['counts'])],
                     'unknown': a.get('unknown', False) or b.get('unknown', False)})
    return {'counterOrder': ['liveBlocks', 'liveBytes', 'cumulativeBlocks', 'cumulativeBytes'],
            'allStackBuckets': rows, 'unknownBucketCount': sum(row['unknown'] for row in rows),
            'crossArmSubtraction': False, 'individualObjectSurvivalProven': False,
            'retainingOwnerProven': False, 'originalGlibcReconciled': False}
