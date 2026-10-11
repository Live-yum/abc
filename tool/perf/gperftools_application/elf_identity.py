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


def elf_metadata_fd(fd, size, deadline, *, necessary_offsets=()):
    reader = MetadataReader(size, lambda off, count: os.pread(fd, count, off), deadline)
    return _elf_metadata(reader, necessary_offsets)


def elf_metadata(data):
    """Compatibility/offline parser; runtime always uses bounded FD pread."""
    reader = MetadataReader(len(data), lambda off, count: data[off:off + count], float('inf'))
    return _elf_metadata(reader, None)


def _elf_metadata(reader, necessary_offsets):
    header_bytes = reader.read(0, 64)
    require(header_bytes[:7] == b'\x7fELF\x02\x01\x01', 'Expected ELF64 little endian')
    header = struct.unpack_from('<HHIQQQIHHHHHH', header_bytes, 16)
    kind, machine, version, _, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, shstr = header
    require(kind in (2, 3) and machine == 62 and version == 1 and ehsize == 64,
            'Unsupported ELF platform/type/header')
    require(phsize == 56 and 0 < phnum <= 256 and shsize == 64 and 0 < shnum <= 65535
            and shstr < shnum, 'Unsupported extended/absent ELF tables')
    phdata = reader.read(phoff, phnum * phsize)
    shdata = reader.read(shoff, shnum * shsize)
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
    build_ids = set()
    for off, size in note_ranges:
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
    require(len(build_ids) == 1 and loads, 'Unique GNU build ID/PT_LOAD required')
    sections = [struct.unpack_from('<IIQQQQIIQQ', shdata, i * 64) for i in range(shnum)]
    shnames = sections[shstr]
    require(shnames[1] == 3, 'ELF section-name table missing')
    section_names = reader.read(shnames[4], shnames[5])
    names = []
    for section in sections:
        start = section[0]
        require(start < len(section_names), 'ELF section-name extent')
        end = section_names.find(b'\x00', start)
        require(start <= end < start + 65536, 'ELF section-name terminator')
        names.append(bytes(section_names[start:end]))
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
    debug_link = None
    for name, section in zip(names, sections):
        if name != b'.gnu_debuglink':
            continue
        require(debug_link is None, 'Duplicate GNU debuglink')
        payload = reader.read(section[4], section[5])
        end = payload.find(b'\x00')
        require(0 < end < 65536, 'GNU debuglink filename extent')
        filename = payload[:end].decode('utf-8', errors='strict')
        require('/' not in filename and filename not in ('.', '..'), 'GNU debuglink unsafe filename')
        crc_offset = (end + 4) & ~3
        require(len(payload) == crc_offset + 4, 'GNU debuglink CRC extent')
        debug_link = {'filename': filename, 'crc32': struct.unpack_from('<I', payload, crc_offset)[0]}
    unsupported_debug = [name.decode('ascii') for name in names
                         if name in (b'.gnu_debugaltlink', b'.debug_sup')]
    proof = reader.proof()
    proof.update(symbolTables=scans, selection='all-symbols-offline' if offsets is None else 'exact-PC-union',
                 necessaryElfOffsets=offsets,
                 offlineResymbolizationSelfContained=False)
    return {'buildId': next(iter(build_ids)), 'ptLoad': loads, **symbols,
            'metadataProof': proof, 'gnuDebuglink': debug_link,
            'unsupportedSupplementaryDebugSections': unsupported_debug,
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
        self.files, self.unique_inputs, self.endpoint_debug = {}, {}, {}
        self.debug_selections, self.indirect_debug = {}, {}
        self.evidence, self.cap_check = Path(evidence), cap_check
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
            self.seal_indirect_debug(deadline)
            save(self.evidence / 'debug-inputs.json', {
                'directPprofSelections': self.debug_selections,
                'standardIndirectCandidates': self.indirect_debug,
                'policy': 'record absence; bind present standard debuglink/build-id candidates; reject unsupported supplementary sections',
                'allPossibleBinutilsExternalReadsProven': False,
                'noDebugDownloads': True}, new=True)
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

    def seal_file(self, path, deadline):
        need_time(deadline)
        path = str(path)
        require(str(Path(path).resolve()) == path, 'Loaded module path is not canonical')
        if path in self.files:
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
        metadata = elf_metadata_fd(fd, info.st_size, deadline)
        path_matches_fd(path, fd, stat_key(info))
        row = dict(path=path, bytes=info.st_size, sha256=digest,
                   device=info.st_dev, inode=info.st_ino,
                   inputPolicy='inplace-system-elf' if system_elf(path) else 'sealed-built-artifact',
                   storagePolicy='retained-FD-and-original-path-no-ELF-copy',
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
        result = []
        current = image
        for level in range(2):
            candidates = []
            selected = None
            for name in self.debug_candidates(current):
                regular = Path(name).is_file()
                candidate = {'path': name, 'regularFile': regular}
                if regular:
                    canonical = str(Path(name).resolve())
                    candidate['canonicalPath'] = canonical
                    debug = self.seal_file(canonical, deadline)
                    require(debug['buildId'] == build_id, 'Official pprof debug candidate BuildID mismatch: ' + name)
                    candidate.update({key: debug[key] for key in ('device', 'inode', 'bytes', 'sha256', 'buildId')})
                    if selected is None:
                        selected = name
                candidates.append(candidate)
            result.append({'level': level + 1, 'image': current,
                           'candidates': candidates, 'selected': selected})
            if selected is None:
                break
            current = selected
        self.debug_selections[image] = result
        return result

    def capture_file(self, path, expected, deadline, cap_check):
        row = dict(self.seal_file(path, deadline))
        if expected is not None:
            require({key: row[key] for key in ('path', 'device', 'inode', 'bytes', 'sha256')} == expected,
                    'Module differs from sealed artifact')
        if row['hasEmbeddedDebugInfo']:
            row['debugInfo'] = {'buildId': row['buildId'], 'sha256': row['sha256'],
                                'kind': 'embedded', 'source': path, 'completeElfRetained': False}
        else:
            candidate = Path('/usr/lib/debug/.build-id') / row['buildId'][:2] / (row['buildId'][2:] + '.debug')
            row['endpointDebugCandidate'] = {'path': str(candidate), 'regularFile': candidate.is_file()}
            if candidate.exists():
                debug_path = str(candidate.resolve())
                debug = self.seal_file(debug_path, deadline)
                require(debug['buildId'] == row['buildId'], 'Installed debug build ID does not match module')
                self.endpoint_debug[path] = debug_path
                row['endpointDebugCandidate']['canonicalPath'] = debug_path
                row['debugInfo'] = {'buildId': row['buildId'], 'sha256': debug['sha256'],
                    'bytes': debug['bytes'], 'kind': 'existing-build-id-match',
                    'source': debug_path, 'completeElfRetained': False,
                    'metadataProof': debug['metadataProof']}
        row['officialDebugSelection'] = self.seal_debug_selection(path, row['buildId'], deadline)
        return row

    def seal_indirect_debug(self, deadline):
        """Bind standard local debuglink/build-ID candidates, not a filesystem scan.

        This records the supported candidate contract. It is not a claim that
        every binutils version's possible external file lookup has been traced.
        Supplementary/DWZ link sections require a separate contract and fail.
        """
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
                need_time(deadline)
                candidate = {'path': name, 'regularFile': Path(name).is_file(), 'expectedCrc32': expected_crc}
                if candidate['regularFile']:
                    canonical = str(Path(name).resolve())
                    debug = self.seal_file(canonical, deadline)
                    require(debug['buildId'] == build_id, 'Indirect debug candidate BuildID mismatch: ' + name)
                    candidate.update(canonicalPath=canonical, **{key: debug[key]
                        for key in ('device', 'inode', 'bytes', 'sha256', 'buildId')})
                    if expected_crc is not None:
                        fd, _ = self.held[canonical]
                        crc, offset = 0, 0
                        while offset < debug['bytes']:
                            need_time(deadline)
                            data = os.pread(fd, min(MAX_ELF_READ, debug['bytes'] - offset), offset)
                            require(data, 'Indirect debug candidate truncated')
                            crc = zlib.crc32(data, crc)
                            offset += len(data)
                        require(crc == expected_crc, 'GNU debuglink CRC mismatch: ' + name)
                        candidate['observedCrc32'] = crc
                candidates.append(candidate)
            self.indirect_debug[path] = candidates

    def prepare_symbols(self, profiles, deadline):
        """Rescan every accepted table; retain all exact candidates for every PC.

        Empty-PC modules still have a complete bounded startup scan proof. No
        unsampled module is skipped by official pprof itself.
        """
        offsets = {path: set() for path in self.records}
        for profile in profiles:
            for bucket in profile['buckets']:
                for pc in bucket['stack']:
                    mappings = [item for item in profile['maps']
                                if item['start'] <= pc < item['end'] and 'x' in item['permissions']]
                    require(len(mappings) == 1, 'Necessary PC lacks unique executable mapping')
                    mapping = mappings[0]
                    if mapping['path'] in self.records:
                        _, offset = normalized_file_pc(pc, mapping, self.records[mapping['path']])
                        offsets[mapping['path']].add(offset)
        self.verify_metadata()
        for path, row in self.records.items():
            need_time(deadline)
            fd, _ = self.held[path]
            metadata = elf_metadata_fd(fd, row['bytes'], deadline, necessary_offsets=offsets[path])
            require(metadata['buildId'] == row['buildId'] and metadata['ptLoad'] == row['ptLoad'],
                    'ELF identity changed during symbol extraction')
            row.update({key: metadata[key] for key in ('dynsym', 'symtab', 'metadataProof')})
            if path in self.endpoint_debug:
                debug_path = self.endpoint_debug[path]
                debug_fd, _ = self.held[debug_path]
                debug = elf_metadata_fd(debug_fd, self.files[debug_path]['bytes'], deadline,
                                        necessary_offsets=offsets[path])
                require(debug['buildId'] == row['buildId'], 'Debug BuildID changed during symbol extraction')
                row['symtab'].extend(debug['symtab'])
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
            save(self.evidence / (row['sha256'] + '-endpoint-symbols.json'), row, new=True)
            self.cap_check()
        self.verify_metadata()
        return {'limits': INPLACE_ELF_LIMITS, 'uniqueElfInputBytes': sum(self.unique_inputs.values()),
                'uniqueElfInputCount': len(self.unique_inputs), 'pathFdBindingAtomic': False,
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
                    require(path.is_file() == candidate['regularFile'],
                            'Official pprof debug selection changed: ' + str(path))
                    if candidate['regularFile']:
                        require(str(path.resolve()) == candidate['canonicalPath'],
                                'Official pprof debug candidate changed: ' + str(path))
        for candidates in self.indirect_debug.values():
            for candidate in candidates:
                path = Path(candidate['path'])
                require(path.is_file() == candidate['regularFile'], 'Indirect debug availability changed')
                if candidate['regularFile']:
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
