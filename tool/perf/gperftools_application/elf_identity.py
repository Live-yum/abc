"""Bound actual loaded ELF bytes, PT_LOAD ranges, build IDs and exact symbols.

No nearest-symbol attribution, debug downloading, process memory reads, or RSS
sampling. All identities come from retained regular-file FDs and target maps.
"""
from __future__ import annotations
import hashlib
import json
import bisect
import os
from pathlib import Path
import stat
import struct
import time
import zlib

from application_contract import (MAX_MAPS, MAX_MODULE, MAX_SYSTEM_ELF, MAX_ARM_ELF_INPUT,
    MAX_ELF_METADATA, MAX_ELF_READ, INPLACE_ELF_LIMITS, map_key,
    normalized_file_pc, parse_maps, require, validate_module_records)
from application_process import save


def need_time(deadline):
    require(time.monotonic() < deadline, 'ELF identity/shared deadline expired')


def stat_key(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def system_elf(path):
    """Only canonical OS library trees receive the explicit system-input cap."""
    return any(str(path).startswith(root) for root in ('/usr/lib/', '/usr/lib64/', '/lib/', '/lib64/'))


def input_cap(path):
    return MAX_SYSTEM_ELF if system_elf(path) else MAX_MODULE


def stream_sha(fd, size, deadline, *, cap=MAX_MODULE):
    """Hash a retained FD with fixed-size pread; never materialize the ELF."""
    require(0 < size <= cap, 'ELF input byte cap exceeded')
    digest, offset = hashlib.sha256(), 0
    while offset < size:
        need_time(deadline)
        chunk = os.pread(fd, min(MAX_ELF_READ, size - offset), offset)
        require(chunk, 'ELF truncated during streaming hash')
        digest.update(chunk)
        offset += len(chunk)
    need_time(deadline)
    require(not os.pread(fd, 1, size), 'ELF grew during streaming hash')
    return digest.hexdigest()


def path_matches_fd(path, fd, expected):
    require(str(Path(path).resolve()) == str(path), 'ELF path ceased to be canonical')
    actual = os.stat(path, follow_symlinks=False)
    require(stat.S_ISREG(actual.st_mode) and stat_key(actual) == expected == stat_key(os.fstat(fd)),
            'ELF path/retained FD metadata changed: ' + str(path))


def file_identity(path, *, deadline=float('inf')):
    # Built artifacts and package tools retain their original 64 MiB limit.
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'Canonical regular path required')
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= MAX_MODULE,
                f'Sealed file exceeds 64 MiB/type cap: {path} ({before.st_size} bytes)')
        digest = stream_sha(fd, before.st_size, deadline)
        path_matches_fd(path, fd, stat_key(before))
        return {'path': str(path), 'device': before.st_dev, 'inode': before.st_ino,
                'bytes': before.st_size, 'sha256': digest}
    finally:
        os.close(fd)


class MetadataReader:
    """Read only ELF metadata ranges; each syscall <=1 MiB and extraction <=64 MiB.

    Extent validation of PT_LOAD never reads its file payload. The cap counts
    unique exact requested metadata ranges conservatively, including overlaps.
    """
    def __init__(self, size, read_at, deadline):
        self.size, self.read_at, self.deadline = size, read_at, deadline
        self.ranges, self.extracted = {}, 0

    def extent(self, offset, size):
        require(0 <= offset <= self.size and 0 <= size <= self.size - offset, 'ELF table extent')

    def read(self, offset, size):
        self.extent(offset, size)
        need_time(self.deadline)
        key = (offset, size)
        if key not in self.ranges:
            require(self.extracted + size <= MAX_ELF_METADATA, 'ELF extracted metadata exceeds 64 MiB')
            self.extracted += size
        data, cursor = bytearray(), offset
        while len(data) < size:
            need_time(self.deadline)
            chunk = self.read_at(cursor, min(MAX_ELF_READ, size - len(data)))
            require(chunk and len(chunk) <= min(MAX_ELF_READ, size - len(data)), 'Truncated ELF metadata read')
            data.extend(chunk)
            cursor += len(chunk)
        digest = hashlib.sha256(data).hexdigest()
        if key in self.ranges:
            require(self.ranges[key] == digest, 'ELF metadata changed within parse')
        self.ranges[key] = digest
        return data

    def proof(self):
        return {'extractedBytes': self.extracted,
                'ranges': [{'offset': start, 'bytes': size, 'sha256': digest}
                           for (start, size), digest in sorted(self.ranges.items())],
                'fullSymbolScanComplete': True, 'completeElfRetained': False}


def elf_metadata_fd(fd, size, deadline, *, necessary_offsets=(), debug_input=False):
    reader = MetadataReader(size, lambda off, count: os.pread(fd, count, off), deadline)
    return _elf_metadata(reader, necessary_offsets, debug_input=debug_input)


def elf_metadata(data):
    """Compatibility/offline parser; runtime always uses bounded FD pread."""
    reader = MetadataReader(len(data), lambda off, count: data[off:off + count], float('inf'))
    return _elf_metadata(reader, None)


def _elf_metadata(reader, necessary_offsets, *, debug_input=False):
    header_bytes = reader.read(0, 64)
    require(header_bytes[:7] == b'\x7fELF\x02\x01\x01', 'Expected ELF64 little endian')
    header = struct.unpack_from('<HHIQQQIHHHHHH', header_bytes, 16)
    kind, machine, version, _, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, shstr = header
    require(kind in ((1, 2, 3) if debug_input else (2, 3)) and machine == 62 and version == 1 and ehsize == 64,
            'Unsupported ELF platform/type/header')
    require((phsize == 56 and 0 < phnum <= 256 or debug_input and phnum == 0 and phsize in (0, 56))
            and shsize == 64 and 0 < shnum <= 65535
            and shstr < shnum, 'Unsupported extended/absent ELF tables')
    phdata = reader.read(phoff, phnum * phsize)
    shdata = reader.read(shoff, shnum * shsize)
    sections = [struct.unpack_from('<IIQQQQIIQQ', shdata, i * 64) for i in range(shnum)]
    loads, note_ranges = [], []
    for i in range(phnum):
        ptype, flags, off, vaddr, _, filesz, memsz, align = struct.unpack_from('<IIQQQQQQ', phdata, i * 56)
        if ptype in (1, 4):
            reader.extent(off, filesz)
        if ptype == 1:
            require(filesz <= memsz and align >= 4096 and align & (align - 1) == 0, 'ELF load alignment')
            loads.append(dict(offset=off, vaddr=vaddr, fileSize=filesz, memorySize=memsz, flags=flags, align=align))
        elif ptype == 4:
            note_ranges.append((off, filesz))
    # Standalone DWZ/debug ELFs can expose the GNU ID in SHT_NOTE only.
    note_ranges.extend((section[4], section[5]) for section in sections if section[1] == 7)
    build_ids = set()
    for off, size in sorted(set(note_ranges)):
        note, cursor = reader.read(off, size), 0
        while cursor < len(note):
            require(len(note) - cursor >= 12, 'Truncated ELF note')
            namesz, descsz, ntype = struct.unpack_from('<III', note, cursor)
            cursor += 12
            name_end, desc_start = cursor + namesz, cursor + ((namesz + 3) & ~3)
            end = desc_start + descsz
            require(name_end <= len(note) and end <= len(note), 'ELF note extent')
            if note[cursor:name_end] == b'GNU\x00' and ntype == 3:
                require(4 <= descsz <= 64, 'ELF build ID extent')
                build_ids.add(note[desc_start:end].hex())
            cursor = desc_start + ((descsz + 3) & ~3)
            require(cursor <= len(note), 'ELF note padding extent')
    require(len(build_ids) == 1 and (loads or debug_input), 'Unique GNU build ID/PT_LOAD required')
    shnames = sections[shstr]
    require(shnames[1] == 3, 'ELF section-name table missing')
    section_names = reader.read(shnames[4], shnames[5])
    names, inventory, inventory_bytes = [], [], 0
    for section_index, section in enumerate(sections):
        start = section[0]
        require(start < len(section_names), 'ELF section-name extent')
        end = section_names.find(b'\x00', start)
        require(start <= end < start + 65536, 'ELF section-name terminator')
        name = bytes(section_names[start:end])
        names.append(name)
        item = dict(index=section_index, name=name.decode('ascii', errors='backslashreplace'),
                    nameBytesHex=name.hex(), type=section[1], flags=section[2],
                    address=section[3], offset=section[4], bytes=section[5],
                    link=section[6], info=section[7], align=section[8], entrySize=section[9])
        inventory_bytes += len(json.dumps(item, sort_keys=True).encode())
        require(inventory_bytes <= 4 << 20, 'ELF section inventory JSON exceeds 4 MiB')
        # NOBITS has no file payload; all other declared sections must be bound.
        if section[1] != 8:
            reader.extent(section[4], section[5])
        inventory.append(item)
    symbols, scans = {'dynsym': [], 'symtab': []}, []
    selected_json_bytes = 0
    offsets = None if necessary_offsets is None else sorted(set(necessary_offsets))
    for section_index, section in enumerate(sections):
        need_time(reader.deadline)
        _, skind, _, _, off, size, link, _, _, entsize = section
        if skind not in (2, 11):
            continue
        require(entsize == 24 and size % 24 == 0 and size // 24 <= 262144 and link < len(sections),
                'ELF symbol table bounds')
        table = reader.read(off, size)
        strings = sections[link]
        require(strings[1] == 3, 'ELF symbol string table missing')
        string_data = reader.read(strings[4], strings[5])
        out = symbols['dynsym' if skind == 11 else 'symtab']
        accepted, matched = 0, 0
        for index in range(size // 24):
            if index % 1024 == 0:
                need_time(reader.deadline)
            name, info, _, shindex, value, length = struct.unpack_from('<IBBHQQ', table, index * 24)
            if shindex == 0 or info & 15 not in (2, 10) or not length:
                continue
            require(name < len(string_data), 'ELF symbol name extent')
            end = string_data.find(b'\x00', name)
            require(name <= end < name + 65536, 'ELF symbol name missing/oversized')
            text = string_data[name:end].decode('utf-8', errors='strict')
            require(value + length < 2**64, 'ELF symbol integer overflow')
            accepted += 1
            hit = bisect.bisect_left(offsets, value) if offsets is not None else 0
            if offsets is None or hit < len(offsets) and offsets[hit] < value + length:
                symbol = {'name': text, 'address': value, 'size': length}
                if offsets is not None:
                    selected_json_bytes += len(json.dumps(symbol, sort_keys=True).encode())
                    require(selected_json_bytes <= 4 << 20, 'Necessary symbol JSON exceeds 4 MiB')
                out.append(symbol)
                matched += 1
        scans.append({'kind': 'dynsym' if skind == 11 else 'symtab', 'sectionIndex': section_index,
                      'offset': off, 'bytes': size, 'sha256': hashlib.sha256(table).hexdigest(),
                      'stringsOffset': strings[4], 'stringsBytes': strings[5],
                      'stringsSha256': hashlib.sha256(string_data).hexdigest(),
                      'entryCount': size // 24, 'acceptedFunctionCount': accepted,
                      'matchedFunctionCount': matched, 'fullScanComplete': True})
    debug_link, alt_link, raw_links = None, None, {}
    for name, section in zip(names, sections):
        if name not in (b'.gnu_debuglink', b'.gnu_debugaltlink', b'.debug_sup'):
            continue
        label = name.decode('ascii')
        require(label not in raw_links, 'Duplicate debug link section: ' + label)
        require(0 < section[5] <= 65536 + 68, 'Debug link payload extent')
        payload = reader.read(section[4], section[5])
        raw_links[label] = {'offset': section[4], 'bytes': section[5],
                            'sha256': hashlib.sha256(payload).hexdigest(), 'rawHex': payload.hex()}
        if name == b'.debug_sup':
            continue  # Recorded exactly; DWARF supplementary interpretation is unknown.
        end = payload.find(b'\x00')
        require(0 < end < 65536, 'GNU debug link filename extent')
        filename = payload[:end].decode('utf-8', errors='strict')
        require(not any(ord(char) < 32 or ord(char) == 127 for char in filename),
                'GNU debug link unsafe filename')
        if name == b'.gnu_debuglink':
            require('/' not in filename and filename not in ('.', '..'), 'GNU debuglink unsafe filename')
            crc_offset = (end + 4) & ~3
            require(len(payload) == crc_offset + 4 and not any(payload[end:crc_offset]), 'GNU debuglink CRC extent')
            debug_link = {'filename': filename, 'crc32': struct.unpack_from('<I', payload, crc_offset)[0]}
        else:
            require(filename not in ('.', '..') and 4 <= len(payload) - end - 1 <= 64,
                    'GNU debugaltlink BuildID extent')
            alt_link = {'filename': filename, 'buildId': payload[end + 1:].hex()}
    unsupported_debug = [name.decode('ascii') for name in names
                         if name in (b'.gnu_debugaltlink', b'.debug_sup')]
    proof = reader.proof()
    proof.update(symbolTables=scans, selection='all-symbols-offline' if offsets is None else 'exact-PC-union',
                 necessaryElfOffsets=offsets,
                 offlineResymbolizationSelfContained=False)
    return {'buildId': next(iter(build_ids)), 'ptLoad': loads, **symbols,
            'metadataProof': proof, 'gnuDebuglink': debug_link, 'gnuDebugaltlink': alt_link,
            'sectionInventory': inventory, 'debugLinkPayloads': raw_links,
            'unsupportedSupplementaryDebugSections': unsupported_debug,
            'debugCapabilities': {'externalResolution': 'deferred-until-actual-PCs',
                'dwarfInterpretation': 'unknown-not-used-for-trusted-functions',
                'supplementary': 'recorded-unresolved' if unsupported_debug else 'not-declared',
                'compressedSections': [item['name'] for item in inventory
                    if item['flags'] & 0x800 or item['name'].startswith('.zdebug')],
                'splitDwarfSections': [item['name'] for item in inventory if item['name'].endswith('.dwo')],
                'splitDwarfAttributes': 'unknown-not-scanned'},
            'debugInfo': None, 'debugInfoPolicy': 'exact-ELF-functions; deferred-bounded-external-debug; no downloads',
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


def target_maps(identity, evidence_path, cap_check):
    evidence_path = Path(evidence_path)
    identity.verify()
    read_start = time.monotonic_ns()
    try:
        fd = os.open('maps', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=identity.proc_fd)
        try:
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                data = stream.read(MAX_MAPS + 1)
        finally:
            os.close(fd)
    except BaseException as exc:
        save(evidence_path.with_suffix('.capture.json'), {
            'stage': evidence_path.stem, 'readStartMonotonicNs': read_start,
            'readEndMonotonicNs': time.monotonic_ns(),
            'rawAvailable': False, 'complete': False,
            'readErrorType': type(exc).__name__, 'savedBeforeParse': True,
            'readLimitBytes': MAX_MAPS + 1,
        }, new=True)
        cap_check()
        raise
    read_end = time.monotonic_ns()
    # Persist the bounded read before either parsing or post-read identity checks.
    # An over-cap read retains only the bounded prefix and explicitly marks it incomplete.
    with evidence_path.open('xb') as stream:
        stream.write(data[:MAX_MAPS])
    save(evidence_path.with_suffix('.capture.json'), {
        'stage': evidence_path.stem, 'readStartMonotonicNs': read_start,
        'readEndMonotonicNs': read_end, 'rawAvailable': True,
        'readBytes': len(data), 'retainedBytes': min(len(data), MAX_MAPS),
        'complete': len(data) <= MAX_MAPS,
        'retainedSha256': hashlib.sha256(data[:MAX_MAPS]).hexdigest(),
        'readLimitBytes': MAX_MAPS + 1, 'savedBeforeParse': True,
    }, new=True)
    cap_check()
    identity.verify()
    require(0 < len(data) <= MAX_MAPS, 'Startup target maps cap')
    return data, parse_maps(data)


class BoundModules:
    def __init__(self, identity, required, module_store, evidence, *, deadline, cap_check, presealed=None):
        self.identity, self.held, self.records, self.deferred = identity, {}, {}, {}
        self.files, self.unique_inputs, self.endpoint_debug = {}, {}, {}
        self.debug_selections, self.indirect_debug = {}, {}
        self.evidence, self.cap_check = Path(evidence), cap_check
        self.transitions = []
        self.module_store = Path(module_store)
        self.module_store.mkdir(mode=0o700, parents=True, exist_ok=True)
        presealed = presealed or {}
        sealed = {**required, **presealed}
        try:
            Path(evidence).mkdir(mode=0o700, parents=True, exist_ok=False)
            data, maps = target_maps(identity, self.evidence / 'startup.maps', cap_check)
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
                save(Path(evidence) / (row['sha256'] + '-' + hashlib.sha256(path.encode()).hexdigest() + '.json'), row, new=True)
                cap_check()
            save(self.evidence / 'startup-debug-policy.json', {
                'externalResolution': 'deferred-until-complete-raw-actual-PC-stage',
                'modulePaths': sorted(self.files),
                'policy': 'identity gate binds actual ELF bytes and mappings; external debug capability is separate',
                'allPossibleBinutilsExternalReadsProven': False,
                'noDebugDownloads': True}, new=True)
            cap_check()
            validate_module_records({'fileExecutableMaps': sorted(self.executable_keys)}, self.records)
            self.verify_metadata()
            _, latest = target_maps(identity, self.evidence / 'startup-consistency.maps', cap_check)
            require({map_key(row) for row in latest if 'x' in row['permissions'] and row['path'].startswith('/')} == self.executable_keys,
                    'Executable module maps changed during startup gate')
            need_time(deadline)
        except BaseException:
            self.close()
            raise

    def seal_file(self, path, deadline, *, debug_input=False):
        need_time(deadline)
        path = str(path)
        require(str(Path(path).resolve()) == path, 'Loaded module path is not canonical')
        if path in self.files:
            require(debug_input or self.files[path].get('identityRole') == 'actual-module',
                    'External debug input cannot establish actual-module identity')
            return self.files[path]
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        self.held[path] = (fd, None)
        info = os.fstat(fd)
        cap = input_cap(path)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= cap,
                f'ELF input exceeds {cap} byte/type cap: {path} ({info.st_size} bytes)')
        self.held[path] = (fd, stat_key(info))
        key = (info.st_dev, info.st_ino)
        if key not in self.unique_inputs:
            require(sum(self.unique_inputs.values()) + info.st_size <= MAX_ARM_ELF_INPUT,
                    'Unique ELF input exceeds 1 GiB per arm')
            self.unique_inputs[key] = info.st_size
        digest = stream_sha(fd, info.st_size, deadline, cap=cap)
        metadata = elf_metadata_fd(fd, info.st_size, deadline, debug_input=debug_input)
        path_matches_fd(path, fd, stat_key(info))
        row = dict(path=path, bytes=info.st_size, sha256=digest,
                   device=info.st_dev, inode=info.st_ino,
                   inputPolicy='inplace-system-elf' if system_elf(path) else 'sealed-built-artifact',
                   storagePolicy='retained-FD-and-original-path-no-ELF-copy',
                   identityRole='external-debug-input' if debug_input else 'actual-module',
                   pathFdBindingAtomic=False, offlineRerunRequiresSameSha256Elf=True,
                   **metadata)
        self.files[path] = row
        save(self.evidence / ('input-' + hashlib.sha256(path.encode()).hexdigest() + '.json'), row, new=True)
        self.cap_check()
        return row

    @staticmethod
    def debug_candidates(image):
        return ['/usr/lib/debug' + image, '/usr/lib/debug' + image + '.debug']

    def seal_debug_selection(self, image, build_id, deadline):
        # Exactly the two paths opened by official pprof DebuggingLibrary. Its
        # caller may invoke it again on the first selected debug image for nm.
        self.ensure_debug_roots([image])
        result, visited = [], {image}
        current = image
        for level in range(2):
            candidates = []
            selected = None
            for name in self.debug_candidates(current):
                candidate = self.debug_candidate(name, build_id, deadline, kind='official-pprof')
                if candidate['regularFile']:
                    if selected is None:
                        selected = name
                candidates.append(candidate)
            result.append({'level': level + 1, 'image': current,
                           'candidates': candidates, 'selected': selected})
            if selected is None:
                break
            canonical = str(Path(selected).resolve())
            require(canonical not in visited, 'Official pprof debug candidate cycle')
            visited.add(canonical)
            current = selected
        self.debug_selections[image] = result
        return result

    def capture_file(self, path, expected, deadline, cap_check):
        """Seal the actual module only. No external filename is opened here."""
        row = dict(self.seal_file(path, deadline))
        if expected is not None:
            require({key: row[key] for key in ('path', 'device', 'inode', 'bytes', 'sha256')} == expected,
                    'Module differs from sealed artifact')
        if row['hasEmbeddedDebugInfo']:
            row['debugInfo'] = {'buildId': row['buildId'], 'sha256': row['sha256'],
                                'kind': 'embedded', 'source': path, 'completeElfRetained': False}
        row['externalDebugResolution'] = {'state': 'deferred', 'reason': 'no-actual-PC-selection-yet'}
        return row

    def ensure_debug_roots(self, images=()):
        # Freeze roots before any debug files are added. They cannot enlarge the
        # authority of their own links. Mapped/build artifacts supply only their
        # containing directories, never an inferred common root such as /.
        if not hasattr(self, 'debug_roots'):
            images = set(images) | {path for path, row in self.files.items()
                                     if row.get('identityRole') != 'external-debug-input'}
            self.debug_roots = tuple(sorted({str(Path(root).resolve()) for root in
                ('/usr/lib', '/usr/lib64', '/lib', '/lib64')} |
                {str(Path(path).parent) for path in images if not system_elf(path)}))
            require('/' not in self.debug_roots, 'Debug input root cannot be the whole filesystem')

    def debug_candidate(self, name, build_id, deadline, *, kind, crc=None):
        need_time(deadline)
        path = Path(name)
        require(path.is_absolute(), 'Debug candidate must be absolute')
        try:
            canonical = str(path.resolve())
        except (OSError, RuntimeError, ValueError) as error:
            require(False, 'Debug candidate path resolution failed: ' + str(error))
        require(any(Path(canonical).is_relative_to(root) for root in self.debug_roots),
                'Debug candidate escapes original system/build roots: ' + str(path))
        present = path.exists() or path.is_symlink()
        require(not present or path.is_file(), 'Debug candidate is not a regular file: ' + str(path))
        candidate = {'path': str(path), 'canonicalPath': canonical, 'regularFile': present,
                     'kind': kind, 'state': 'present-bound' if present else 'absent',
                     'expectedBuildId': build_id, 'expectedCrc32': crc}
        if present:
            debug = self.seal_file(canonical, deadline, debug_input=True)
            require(debug['buildId'] == build_id, 'Debug candidate BuildID mismatch: ' + str(path))
            candidate.update({key: debug[key] for key in ('device', 'inode', 'bytes', 'sha256', 'buildId')})
            if crc is not None:
                fd, expected = self.held[canonical]
                observed, offset = 0, 0
                while offset < debug['bytes']:
                    need_time(deadline)
                    data = os.pread(fd, min(MAX_ELF_READ, debug['bytes'] - offset), offset)
                    require(data, 'Indirect debug candidate truncated')
                    observed = zlib.crc32(data, observed)
                    offset += len(data)
                require(observed == crc, 'GNU debuglink CRC mismatch: ' + str(path))
                path_matches_fd(canonical, fd, expected)
                candidate['observedCrc32'] = observed
        return candidate

    def resolve_symbol_debug(self, selected_paths, deadline):
        """Resolve only selected modules and their bounded, standard local chain.

        Missing links/capability stay explicit unknown. Present mismatched,
        escaping, malformed or cyclic links still fail. These checks are not
        syscall tracing and cannot atomically constrain official tool reads.
        """
        self.ensure_debug_roots(selected_paths)
        graph, active, done, candidate_json_bytes = {}, set(), set(), 0

        def visit(path):
            nonlocal candidate_json_bytes
            need_time(deadline)
            require(path not in active, 'External debug link cycle: ' + path)
            if path in done:
                return
            require(len(active) < 128 and len(done) + len(active) < 4096,
                    'External debug chain metadata bound exceeded')
            active.add(path)
            row, candidates = self.files[path], []
            link = row.get('gnuDebuglink')
            expected = []
            if link:
                parent, filename = Path(path).parent, link['filename']
                for name in (parent / filename, parent / '.debug' / filename,
                             Path('/usr/lib/debug' + str(parent)) / filename):
                    expected.append((str(name), row['buildId'], 'gnu-debuglink', link['crc32']))
            build_id = row['buildId']
            expected.append(('/usr/lib/debug/.build-id/' + build_id[:2] + '/' + build_id[2:] + '.debug',
                             build_id, 'build-id', None))
            alt = row.get('gnuDebugaltlink')
            if alt:
                filename = Path(alt['filename'])
                name = filename if filename.is_absolute() else Path(path).parent / filename
                expected.append((str(name), alt['buildId'], 'gnu-debugaltlink', None))
                expected.append(('/usr/lib/debug/.build-id/' + alt['buildId'][:2] + '/' + alt['buildId'][2:] + '.debug',
                                 alt['buildId'], 'gnu-debugaltlink-build-id', None))
            seen = set()
            for name, expected_id, kind, crc in expected:
                key = (name, expected_id, kind, crc)
                if key in seen:
                    continue
                seen.add(key)
                candidate = self.debug_candidate(name, expected_id, deadline, kind=kind, crc=crc)
                candidate_json_bytes += len(json.dumps(candidate, sort_keys=True).encode())
                require(candidate_json_bytes <= 4 << 20, 'External debug candidate JSON exceeds 4 MiB')
                candidates.append(candidate)
                if candidate['regularFile']:
                    target = candidate['canonicalPath']
                    # The build-ID path of an already-selected debug file is an
                    # identity alias, not a supplementary recursive dependency.
                    if kind == 'build-id' and target in active:
                        candidate['identityAlias'] = True
                    else:
                        visit(target)
            active.remove(path)
            done.add(path)
            graph[path] = candidates
            self.indirect_debug[path] = candidates

        for path in selected_paths:
            row = self.records[path]
            row['officialDebugSelection'] = self.seal_debug_selection(path, row['buildId'], deadline)
            visit(path)
            for level in row['officialDebugSelection']:
                for candidate in level['candidates']:
                    if candidate['regularFile']:
                        visit(candidate['canonicalPath'])
            if not row['hasEmbeddedDebugInfo']:
                candidate = next(item for item in graph[path] if item['kind'] == 'build-id')
                row['endpointDebugCandidate'] = candidate
                if candidate['regularFile']:
                    debug_path = candidate['canonicalPath']
                    debug = self.files[debug_path]
                    self.endpoint_debug[path] = debug_path
                    row['debugInfo'] = {'buildId': row['buildId'], 'sha256': debug['sha256'],
                        'bytes': debug['bytes'], 'kind': 'existing-build-id-match', 'source': debug_path,
                        'completeElfRetained': False, 'metadataProof': debug['metadataProof']}
            alt_candidates = [item for item in graph[path] if item['kind'].startswith('gnu-debugaltlink')]
            row['externalDebugResolution'] = {'state': 'resolved-candidates-capability-limited',
                'supplementary': [{'path': item['path'], 'state': item['state'], 'kind': item['kind'],
                                  'expectedBuildId': item['expectedBuildId']} for item in alt_candidates],
                'dwarfFunctionAttribution': 'unknown-not-used',
                'trustedFunctions': 'only-bound-exact-nonzero-ELF-symbol-ranges'}
            row['debugCapabilities'] = dict(row['debugCapabilities'], externalResolution='bounded-candidates-recorded')
        self.verify_metadata()
        save(self.evidence / 'debug-inputs.json', {
            'selectedModulePaths': selected_paths,
            'directPprofSelections': self.debug_selections,
            'standardIndirectCandidates': self.indirect_debug,
            'allowedRoots': self.debug_roots,
            'policy': 'record absent; bind present; reject malformed/escaping/cyclic/mismatched/replaced inputs',
            'allPossibleBinutilsExternalReadsProven': False, 'pathFdBindingAtomic': False,
            'noDebugDownloads': True}, new=True)
        self.cap_check()

    def seal_indirect_debug(self, deadline):
        """Bind standard local debuglink/build-ID candidates, not a filesystem scan.

        This records the supported candidate contract. It is not a claim that
        every binutils version's possible external file lookup has been traced.
        Supplementary/DWZ link sections require a separate contract and fail.
        """
        self.ensure_debug_roots()
        while set(self.files) - set(self.indirect_debug):
            path = sorted(set(self.files) - set(self.indirect_debug))[0]
            row = self.files[path]
            require(not row['unsupportedSupplementaryDebugSections'],
                    'Unsupported supplementary debug input: ' + path)
            expected = {}
            link = row['gnuDebuglink']
            if link:
                filename, parent = link['filename'], Path(path).parent
                for candidate in (parent / filename, parent / '.debug' / filename,
                                  Path('/usr/lib/debug' + str(parent)) / filename):
                    expected[str(candidate)] = link['crc32']
            build_id = row['buildId']
            build_id_path = '/usr/lib/debug/.build-id/' + build_id[:2] + '/' + build_id[2:] + '.debug'
            expected.setdefault(build_id_path, None)
            candidates = []
            for name, expected_crc in expected.items():
                candidate = self.debug_candidate(name, build_id, deadline,
                    kind='legacy-standard', crc=expected_crc)
                candidates.append(candidate)
            self.indirect_debug[path] = candidates

    def prepare_symbols(self, profiles, deadline):
        """Select all actual PCs, including zero-live historical buckets.

        Empty-PC modules still have a complete bounded startup scan proof. No
        external debug path for an unsampled module is resolved by this stage.
        Official tool reads are separately disclosed as not exhaustively traced.
        """
        offsets = {path: set() for path in self.records}
        for profile in profiles:
            for bucket in profile['buckets']:
                for pc in bucket['stack']:
                    mappings = [item for item in profile['maps']
                                if item['start'] <= pc < item['end'] and 'x' in item['permissions']]
                    require(len(mappings) == 1, 'Necessary PC lacks unique executable mapping')
                    mapping = mappings[0]
                    require(not mapping['path'].startswith('/') or mapping['path'] in self.records,
                            'Necessary file PC lacks sealed module')
                    if mapping['path'] in self.records:
                        _, offset = normalized_file_pc(pc, mapping, self.records[mapping['path']])
                        offsets[mapping['path']].add(offset)
        self.rehash(deadline)
        selected = sorted(path for path, pcs in offsets.items() if pcs)
        self.resolve_symbol_debug(selected, deadline)
        for path in selected:
            row = self.records[path]
            need_time(deadline)
            fd, _ = self.held[path]
            metadata = elf_metadata_fd(fd, row['bytes'], deadline, necessary_offsets=offsets[path])
            require(metadata['buildId'] == row['buildId'] and metadata['ptLoad'] == row['ptLoad'],
                    'ELF identity changed during symbol extraction')
            require(all(metadata[key] == row[key] for key in
                        ('sectionInventory', 'debugLinkPayloads', 'gnuDebuglink', 'gnuDebugaltlink')),
                    'ELF debug metadata changed during symbol extraction')
            row.update({key: metadata[key] for key in ('dynsym', 'symtab', 'metadataProof')})
            if path in self.endpoint_debug:
                debug_path = self.endpoint_debug[path]
                debug_fd, _ = self.held[debug_path]
                debug = elf_metadata_fd(debug_fd, self.files[debug_path]['bytes'], deadline,
                                        necessary_offsets=offsets[path], debug_input=True)
                require(debug['buildId'] == row['buildId'], 'Debug BuildID changed during symbol extraction')
                if debug['elfType'] == row['elfType']:
                    row['symtab'].extend(debug['symtab'])
                else:
                    row['debugInfo']['symbolCapability'] = 'unknown-incompatible-ELF-address-space'
                row['debugInfo']['metadataProof'] = debug['metadataProof']
            ordered = sorted({(symbol['address'], symbol['address'] + symbol['size'], symbol['name'])
                              for kind in ('dynsym', 'symtab') for symbol in row[kind]})
            starts, ends, peak = [], [], 0
            for start, end, _ in ordered:
                starts.append(start)
                peak = max(peak, end)
                ends.append(peak)
            candidates, candidate_json_bytes = [], 0
            for pc in sorted(offsets[path]):
                need_time(deadline)
                names, index = set(), bisect.bisect_right(starts, pc) - 1
                while index >= 0 and ends[index] > pc:
                    start, end, name = ordered[index]
                    if start <= pc < end:
                        names.add(name)
                    index -= 1
                item = {'elfOffset': pc, 'exactRangeSymbolCandidates': sorted(names)}
                candidate_json_bytes += len(json.dumps(item, sort_keys=True).encode())
                require(candidate_json_bytes <= 4 << 20, 'Per-PC candidate JSON exceeds 4 MiB')
                candidates.append(item)
            row['metadataProof']['perPcCandidates'] = candidates
            save(self.evidence / (row['sha256'] + '-' + hashlib.sha256(path.encode()).hexdigest() + '-endpoint-symbols.json'), row, new=True)
            self.cap_check()
        self.rehash(deadline)
        return {'limits': INPLACE_ELF_LIMITS, 'uniqueElfInputBytes': sum(self.unique_inputs.values()),
                'uniqueElfInputCount': len(self.unique_inputs), 'pathFdBindingAtomic': False,
                'selectedModulePaths': selected,
                'unobservedModulePaths': sorted(set(self.records) - set(selected)),
                'deferredUnloadedModulePaths': sorted(self.deferred),
                'externalDebugStage': 'after-complete-raw-actual-PC-selection',
                'allPossibleBinutilsExternalReadsProven': False,
                'offlineResymbolizationSelfContained': False,
                'requiresSameSha256ElfAndDebugFilesForOfflineRerun': True}

    @staticmethod
    def bind_mappings(row, mapped):
        require(mapped and all(item['inode'] == row['inode'] and item['device'] ==
                (os.major(row['device']), os.minor(row['device'])) for item in mapped),
                'Mapped module device/inode differs from sealed retained ELF')
        row['loadBias'] = load_bias(mapped, row)
        row['loadedIdentityProven'] = True

    def verify_metadata(self):
        for path, (fd, expected) in self.held.items():
            path_matches_fd(path, fd, expected)
        for image, levels in self.debug_selections.items():
            for level in levels:
                for candidate in level['candidates']:
                    path = Path(candidate['path'])
                    present = path.exists() or path.is_symlink()
                    require(present == candidate['regularFile'] and (not present or path.is_file()),
                            'Official pprof debug selection changed: ' + str(path))
                    if candidate.get('canonicalPath') is not None:
                        require(str(path.resolve()) == candidate['canonicalPath'],
                                'Official pprof debug candidate changed: ' + str(path))
        for candidates in self.indirect_debug.values():
            for candidate in candidates:
                path = Path(candidate['path'])
                present = path.exists() or path.is_symlink()
                require(present == candidate['regularFile'] and (not present or path.is_file()),
                        'Indirect debug availability changed')
                if candidate.get('canonicalPath') is not None:
                    require(str(path.resolve()) == candidate['canonicalPath'], 'Indirect debug path changed')
        for row in [*self.records.values(), *self.deferred.values()]:
            if 'endpointDebugCandidate' in row:
                candidate = row['endpointDebugCandidate']
                path = Path(candidate['path'])
                require(path.is_file() == candidate['regularFile'], 'Endpoint debug availability changed')
                if candidate['regularFile']:
                    require(str(path.resolve()) == candidate['canonicalPath'], 'Endpoint debug path changed')

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
        """Pre/post tool check; retained FD is NOT an atomic binding for pprof.

        Official pprof opens original paths. These checks detect ordinary path
        replacement and in-place change, not a transient swap during execution.
        """
        self.verify_metadata()
        for path, (fd, expected) in self.held.items():
            row = self.files[path]
            digest = stream_sha(fd, row['bytes'], deadline, cap=input_cap(path))
            require(digest == row['sha256'], 'Retained module bytes changed: ' + path)
            path_matches_fd(path, fd, expected)
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
