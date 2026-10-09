#!/usr/bin/env python3
"""Validate one fixed-product retention observation without acceptance claims.

The unchanged control validator supplies workload, frame, in-process OS,
checkpoint, quiet-period and fixed-slot checks. Only its internal dispatch arm
is product-os-only; neither reports nor raw evidence are relabelled. External
OS validation is copied with exactly the real arm/product identity substituted.
All original received frames and both independent clocks remain intact.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

import computer_memory_validate as original
import memory_probe_control_validate as control
import native_retention_protocol as protocol
from computer_memory_validate import digest, integer, load_json, require, sha

SCHEMA = 'abc.native-retention-validation.v1'
ARM = 'native-retention'
PRODUCT_COMMIT = protocol.PRODUCT_COMMIT
PRODUCT_TREE = protocol.PRODUCT_TREE
SCHEDULE_SHA256 = control.SCHEDULE_SHA256
PYTHON_CLOCK, DART_CLOCK = control.PYTHON_CLOCK, control.DART_CLOCK
REQUEST_FIELDS = control.REQUEST_FIELDS
endpoint_plan, metrics = control.endpoint_plan, control.metrics
TARGET = 'integration_test/computer_native_retention_test.dart'
SUPPORT = 'integration_test/support/native_retention_probe.dart'
INSPECTED_GLIBC = {'2.39', '2.41'}
SAMPLE_FIELDS = {'schema', 'sequence', 'status', 'reason', 'startUs', 'endUs',
                 'clockDomain', 'atomic', 'sizeTBytes', 'mallinfo2StructBytes',
                 'glibcVersion', 'fields'}
CATEGORY_OPTIONAL = ('pssAnonymousBytes', 'pssFileBytes', 'pssSharedMemoryBytes',
                     'anonymousBytes', 'swapBytes', 'privateHugetlbBytes')
CATEGORY_REQUIRED = ('smapsRssBytes', 'pssBytes', 'privateCleanBytes', 'privateDirtyBytes')
CATEGORY_FIELDS = {'schema', 'sequence', 'externalOsSequence', 'phase', 'metadata',
                   'clockDomain', 'atomic', 'startNs', 'endNs',
                   *CATEGORY_OPTIONAL, *CATEGORY_REQUIRED}


def source_names():
    """Every retained native-retention source, including validator/tests, is hashed."""
    root = Path(__file__).parent
    return {TARGET, SUPPORT} | {
        'tool/perf/' + path.name for path in root.glob('native_retention*')
        if path.suffix in ('.py', '.c', '.json') and path.is_file()
    }


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON object key')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


class RetentionValidator(control.ControlValidator):
    def __init__(self, report, raw_directory, build, expected_commit, build_sha256,
                 external, external_directory, source=None, derivation=None,
                 helper_build=None):
        super().__init__(report, raw_directory, build, expected_commit, build_sha256,
                         external, external_directory)
        # Select only inherited checks for the same unchanged product workload.
        # The real native-retention identity is validated directly below.
        self.arm = 'product-os-only'
        self.source = source
        self.derivation = derivation
        self.helper_build = helper_build
        self.retention_files = []
        self.retention_summary = None
        self.attribution_available = False
        self.availability_reasons = []

    def validate_header(self):
        report = self.report
        require(report['schema'] == 'abc.native-retention.v1', 'unknown native retention report schema')
        require(report['status'] == 'observed' and report.get('failure') is None
                and report.get('failureStack') is None, 'failed or partial control run cannot pass')
        require(report['arm'] == ARM and report['baseProductCommit'] == PRODUCT_COMMIT,
                'native retention product identity differs')
        require(self.expected_commit not in (PRODUCT_COMMIT, control.BASE_COMMIT),
                'a clean derived diagnostic commit is required')
        integer(report['hostPid'], 'host PID', 1)
        integer(report['vmProbeCalls'], 'VM invocation count')
        integer(report['expectedNativeWorkers'], 'native worker count', 1)
        require(report['buildMode'] == 'profile' and report['inputFormat'] == 'wld-only',
                'real profile WLD-only build required')
        require(report['plannedCycles'] == report['completedCycles'] == 8,
                'exactly eight complete control cycles required')
        require(report['plannedCheckpoints'] == len(report['memoryPoints']) == 17,
                'exactly 17 control checkpoints required')
        require(report['vmProbeCalls'] == 0 and report['expectedNativeWorkers'] == 1,
                'native retention must have zero VM invocations and one native worker')
        require(report['inProcessOsSamplerRetained'] is True and report['externalOsSamplerEnabled'] is True,
                'both original in-process and external OS samplers must be retained')
        require(self.root.is_dir() and report['raw']['directory'] == self.root.name,
                'raw directory missing or belongs to another run')
        require(report['drainPolicy'] == self.schedule['drainPolicy'], 'fixed drain policy differs')
        require(report['scheduleSha256'] == SCHEDULE_SHA256, 'report schedule hash is not the pinned schedule')
        require(self.schedule['schema'] == 'abc.memory-probe-control-schedule.v1'
                and self.schedule['source']['commit'] == control.BASE_COMMIT,
                'invalid reference schedule')
        integer(report['scheduleOriginUs'], 'Dart schedule origin', 1)
        protocol.validate_report_contract(report)

    def validate_provenance(self):
        # Skip ControlValidator's old-product provenance; preserve every original
        # build/runtime/hash check and add the new fixed-product manifests.
        original.Validator.validate_provenance(self)
        files = self.build['sourceFilesSha256']
        require(source_names() <= set(files), 'native retention source hashes missing from build provenance')
        require(files['tool/perf/memory_probe_control_schedule.json'] == SCHEDULE_SHA256,
                'build did not use the pinned control schedule')
        require(digest(Path(__file__).with_name('memory_probe_control_schedule.json')) == SCHEDULE_SHA256,
                'validator reference schedule bytes differ from pinned source')
        self.validate_retention_provenance()

    def evidence_document(self, name, supplied=None):
        path = self.external_root / name
        require(path.is_file() and not path.is_symlink(), 'missing or linked retention provenance: ' + name)
        document = strict_json(path.read_bytes())
        require(isinstance(document, dict), 'retention provenance object required: ' + name)
        require(supplied is None or supplied == document, 'provided retention provenance differs: ' + name)
        return document, digest(path)

    def validate_retention_provenance(self):
        source, source_sha = self.evidence_document('source.json', self.source)
        derivation, derivation_sha = self.evidence_document('derivation.json', self.derivation)
        helper, helper_sha = self.evidence_document('helper-build.json', self.helper_build)
        self.source, self.derivation, self.helper_build = source, derivation, helper
        require(source['schema'] == 'abc.native-retention-source.v1'
                and derivation['schema'] == 'abc.native-retention-derivation.v1',
                'unknown retention source or derivation schema')
        require(source['derivationSha256'] == derivation_sha and source['productPathsUnchanged'] is True,
                'source/derivation digest or unchanged product assertion differs')
        for name in ('baseCommit', 'baseTree', 'derivedCommit', 'derivedTree', 'overlaySourceCommit',
                     'patchFile', 'patchSha256', 'schedule', 'scheduleSha256', 'changedPaths',
                     'overlayFiles', 'overlayFilesSha256', 'productChangesAllowed', 'localCommitOnly'):
            require(source[name] == derivation[name], 'source/derivation identity differs: ' + name)
        require(source['baseCommit'] == PRODUCT_COMMIT and source['baseTree'] == PRODUCT_TREE
                and source['derivedCommit'] == self.expected_commit,
                'source manifest does not identify the fixed final product derivation')
        require(source['productChangesAllowed'] is False and source['localCommitOnly'] is True,
                'source permits product changes or publication')
        for key in ('derivedTree', 'overlaySourceCommit'):
            require(isinstance(source[key], str) and re.fullmatch('[0-9a-f]{40}', source[key]),
                    'malformed retention source Git identity: ' + key)
        require(source['schedule'] == 'tool/perf/memory_probe_control_schedule.json'
                and source['scheduleSha256'] == SCHEDULE_SHA256,
                'source schedule identity differs')
        require(source['patchFile'] == 'diagnostic-overlay.patch', 'unsafe derivation patch filename')
        patch = self.external_root / source['patchFile']
        require(patch.is_file() and not patch.is_symlink()
                and digest(patch) == sha(source['patchSha256']), 'derivation patch missing or digest differs')
        overlay, product = source['overlayFiles'], source['productFiles']
        require(isinstance(overlay, dict) and isinstance(product, dict) and product
                and not set(overlay) & set(product), 'source product and overlay inventories overlap or are missing')
        require(source['changedPaths'] == sorted(overlay), 'source changed paths differ from additions inventory')
        require(source_names() <= set(overlay), 'native retention sources missing from derivation overlay')
        for group, files in (('product', product), ('overlay', overlay)):
            for name, item in files.items():
                require(isinstance(name, str) and name and not Path(name).is_absolute()
                        and all(part not in ('', '.', '..', '.git') for part in name.split('/'))
                        and '\\' not in name, 'unsafe retention source path')
                require(isinstance(item, dict) and set(item) == {'mode', 'gitBlob', 'sha256', 'bytes'},
                        'source file identity must contain exact blob/mode/hash/size')
                require(item['mode'] in (('100644', '100755') if group == 'overlay'
                                         else ('100644', '100755', '120000')),
                        'source file mode differs')
                require(isinstance(item['gitBlob'], str) and re.fullmatch('[0-9a-f]{40}', item['gitBlob']),
                        'source Git blob malformed')
                sha(item['sha256'])
                integer(item['bytes'], 'source file bytes')
                if group == 'overlay':
                    require(name in (TARGET, SUPPORT, '.github/workflows/native-retention.yml')
                            or (name.startswith('tool/perf/native_retention')
                                and '/' not in name[len('tool/perf/'):]),
                            'overlay changes a path outside the new diagnostic allowlist')
        require(source['overlayFilesSha256'] == {name: item['sha256'] for name, item in overlay.items()},
                'source overlay hash inventory differs')
        all_files = {**product, **overlay}
        for name, expected in self.build['sourceFilesSha256'].items():
            require(name in all_files and expected == all_files[name]['sha256'],
                    'build/source exact file hash differs: ' + name)
        # Ensure this validator and the diagnostic sources being evaluated are
        # those recorded by the derived source, rather than a newer local copy.
        repo = Path(__file__).resolve().parents[2]
        for name in source_names():
            require(digest(repo / name) == overlay[name]['sha256'],
                    'validator/diagnostic source bytes differ from recorded build: ' + name)
        require(helper['schema'] == 'abc.native-retention-helper-build.v1' and helper['status'] == 'built'
                and helper['outsideApplicationCheckout'] is True
                and helper['applicationLaunched'] is False and helper['downloadedDependencies'] is False,
                'helper build incomplete or outside observation-only scope')
        require(helper['source'] == {'path': 'tool/perf/native_retention_probe.c',
                                    'sha256': overlay['tool/perf/native_retention_probe.c']['sha256']},
                'helper was not built from the recorded diagnostic source')
        require(helper['helperFile'] == 'libabc_native_retention_probe.so', 'unsafe helper filename')
        require(isinstance(helper['helperPath'], str) and Path(helper['helperPath']).is_absolute(),
                'helper build path must be explicit and absolute')
        sha(helper['helperSha256'])
        integer(helper['helperBytes'], 'helper binary bytes', 1)
        helper_root = self.external_root / 'helper'
        require(helper_root.is_dir() and not helper_root.is_symlink(), 'preserved helper directory missing or linked')

        def helper_file(name, expected, expected_bytes=None):
            require(isinstance(name, str) and Path(name).name == name and name not in ('', '.', '..'),
                    'unsafe helper evidence filename')
            path = helper_root / name
            require(path.is_file() and not path.is_symlink() and digest(path) == sha(expected),
                    'preserved helper evidence missing or digest differs: ' + name)
            if expected_bytes is not None:
                require(path.stat().st_size == expected_bytes, 'helper binary length differs')

        helper_file(helper['helperFile'], helper['helperSha256'], helper['helperBytes'])
        require(helper['dependencyFile'] == 'helper.d', 'unsafe compiler dependency filename')
        helper_file(helper['dependencyFile'], helper['dependencySha256'])
        compiler = helper['compiler']
        sha(compiler['sha256'])
        require(all(isinstance(compiler[key], str) and compiler[key] for key in ('path', 'version', 'target')),
                'helper compiler identity missing')
        headers = helper['headers']
        require(isinstance(headers, dict) and headers, 'helper compiler header inventory missing')
        for name, item in headers.items():
            require(isinstance(name, str) and Path(name).is_absolute(), 'helper header path must be absolute')
            sha(item['sha256'])
            integer(item['bytes'], 'helper header bytes', 1)
        malloc_header = helper['mallocHeader']
        require(Path(malloc_header['path']).name == 'malloc.h'
                and headers[malloc_header['path']] == {key: malloc_header[key] for key in ('sha256', 'bytes')},
                'official malloc.h does not match actual compiler header inventory')
        runtime = helper['runtime']
        require(runtime['scope'] == 'fresh-native-build-contract-process-only',
                'helper build process support must not be presented as application support')
        require(isinstance(runtime['runtimeLibcVersion'], str)
                and re.fullmatch(r'[0-9]+\.[0-9]+', runtime['runtimeLibcVersion']),
                'helper runtime libc version malformed')
        sha(runtime['libcSha256'])
        for key in ('headerGlibcMajor', 'headerGlibcMinor', 'sizeTBytes', 'mallinfo2StructBytes', 'helperStatus'):
            integer(runtime[key], 'helper ' + key)
        require(runtime['sizeTBytes'] in (4, 8)
                and runtime['mallinfo2StructBytes'] in (0, 10 * runtime['sizeTBytes'])
                and runtime['helperStatus'] in range(5), 'helper official-header ABI metadata invalid')
        require((runtime['helperStatus'] == 0 and runtime['abiContractMatched'] is True)
                or (runtime['helperStatus'] != 0 and runtime['abiContractMatched'] is None),
                'helper ABI contract missing or unsupported status fabricated')
        known = runtime['runtimeLibcVersion'] in INSPECTED_GLIBC
        require(runtime['inspectedUpstreamFamily'] is known and runtime['sourceReviewRequired'] is (not known),
                'helper libc semantics claims differ from inspected upstream versions')
        for package in (compiler['package'], malloc_header['package'], runtime['package']):
            require(isinstance(package, dict) and package.get('status') in ('available', 'unavailable'),
                    'compiler/header/libc package identity missing')
            if package['status'] == 'available':
                require(isinstance(package.get('packages'), list) and package['packages']
                        and isinstance(package.get('metadata'), str) and package['metadata']
                        and package.get('queryReturnCode') == 0, 'available package identity incomplete')
            else:
                require(bool(package.get('reason')) or 'queryReturnCode' in package,
                        'unavailable package identity reason missing')
        commands = helper['commands']
        required = {'compiler-version', 'compiler-target', 'compile-helper',
                    'compile-build-contract', 'run-build-contract'}
        require(isinstance(commands, list) and required <= {row['name'] for row in commands},
                'helper compiler/ABI command evidence missing')
        require(len({row['name'] for row in commands}) == len(commands), 'duplicate helper build command')
        for row in commands:
            require(isinstance(row['argv'], list) and row['argv']
                    and all(isinstance(item, str) for item in row['argv'])
                    and row['timeoutSeconds'] == 60 and row.get('timedOut') is not True,
                    'helper command arguments or bounded timeout differ')
            require(type(row['returnCode']) is int and (row['name'] not in required or row['returnCode'] == 0),
                    'required helper build command failed')
            for stream in ('stdout', 'stderr'):
                helper_file(row[stream + 'File'], row[stream + 'Sha256'])
        compile_command = next(row for row in commands if row['name'] == 'compile-helper')
        require(helper['helperCommand'] == compile_command['argv'], 'helper compile command differs from journal')
        contract = helper['buildContract']
        helper_file(contract['sourceFile'], contract['sourceSha256'])
        helper_file(contract['executableFile'], contract['executableSha256'])
        for sample in self.report['allocatorCalls']:
            require(sample['sizeTBytes'] == runtime['sizeTBytes']
                    and sample['mallinfo2StructBytes'] == (runtime['mallinfo2StructBytes'] or None),
                    'application allocator ABI differs from compiled helper')
            require(sample['glibcVersion'] in (None, runtime['runtimeLibcVersion']),
                    'application libc version differs from helper build runtime')
        links = {'sourceSha256': source_sha, 'derivationSha256': derivation_sha,
                 'helperBuildSha256': helper_sha, 'helperSha256': helper['helperSha256'],
                 'nativeEngineSha256': self.build['artifacts']['libabc_engine.so']['sha256']}
        require(self.build['nativeRetentionProvenance'] == links
                and self.report['runtime']['nativeRetentionProvenance'] == links,
                'build/runtime retention provenance links differ from immutable manifests')
        execution = self.report['runtime']['nativeRetentionExecution']
        require(set(execution) == {'sourceUnchangedAfterRun', 'helperUnchangedAfterRun',
                'productBinariesUnchangedAfterRun', 'buildExitCode', 'driverExitCode', 'processInvocations'}
                and all(execution[key] is True for key in ('sourceUnchangedAfterRun',
                    'helperUnchangedAfterRun', 'productBinariesUnchangedAfterRun'))
                and type(execution['buildExitCode']) is int and execution['buildExitCode'] == 0
                and type(execution['driverExitCode']) is int and execution['driverExitCode'] == 0
                and type(execution['processInvocations']) is int and execution['processInvocations'] == 1,
                'post-run source/helper/product verification or single-process execution failed')
        self.validate_original_reports()

    def validate_original_reports(self):
        descriptor = self.report['runtime']['rawTargetReport']
        require(set(descriptor) == {'file', 'sha256'}
                and descriptor['file'] in ('native-retention.raw-report.json', 'native-retention.standalone.json'),
                'unsafe raw target report descriptor')
        raw_target, raw_sha = self.evidence_document(descriptor['file'])
        require(raw_sha == sha(descriptor['sha256']), 'raw target report SHA-256 mismatch')
        attachments = ('buildProvenanceSha256', 'sourceTreeSha256', 'provenanceAttachment',
                       'nativeRetentionProvenance', 'nativeRetentionExecution', 'rawTargetReport')
        require(not set(attachments) & set(raw_target['runtime']) and 'externalOs' not in raw_target,
                'raw target report already contains runner attachments')
        expected = copy.deepcopy(raw_target)
        expected['runtime'].update({key: self.report['runtime'][key] for key in attachments})
        expected['externalOs'] = self.external
        require(expected == self.report, 'enriched report changed original target evidence')
        compiler_build, _ = self.evidence_document('native-retention.compiler-build.json')
        require('nativeRetentionProvenance' not in compiler_build,
                'original compiler build already contains runner attachment')
        require({**compiler_build, 'nativeRetentionProvenance': self.build['nativeRetentionProvenance']}
                == self.build, 'enriched build changed original compiler evidence')

    def external_file(self, descriptor, expected_name):
        name = descriptor['file']
        require(name == expected_name and Path(name).name == name,
                'unsafe retention raw filename')
        path = self.external_root / name
        require(path.is_file() and not path.is_symlink(), 'retention raw file missing or symbolic link')
        require(path.resolve() not in {(self.root / file).resolve() for file in self.files}
                and path.resolve() != (self.external_root / self.external['file']).resolve(),
                'retention raw files must be separate from original raw evidence')
        return path

    def scan_retention(self, descriptor, expected_name, count, consume):
        path = self.external_file(descriptor, expected_name)
        require(integer(descriptor['count'], 'retention raw count') == count,
                'retention raw declared count differs')
        expected_bytes = integer(descriptor['bytes'], 'retention raw bytes', 1)
        expected_sha = sha(descriptor['sha256'])
        hasher, byte_count, observed = hashlib.sha256(), 0, 0
        with path.open('rb') as stream:
            while True:
                # This is a scalar-metadata structural limit, not a performance
                # threshold. A legitimate fixed-shape row is far smaller.
                line = stream.readline(65537)
                if not line:
                    break
                require(len(line) <= 65536 and line.endswith(b'\n'),
                        'retention raw JSONL line oversized or incomplete')
                hasher.update(line)
                byte_count += len(line)
                row = strict_json(line)
                require(isinstance(row, dict), 'retention raw object required')
                require(observed < count, 'retention raw has extra rows')
                consume(row, observed)
                observed += 1
        require(observed == count, 'retention raw missing rows')
        require(byte_count == expected_bytes and hasher.hexdigest() == expected_sha,
                'retention raw bytes/SHA-256 mismatch')
        self.retention_files.append({'file': path.name, 'bytes': byte_count,
                                     'sha256': expected_sha, 'count': observed})

    def validate_allocator(self):
        calls = self.report['allocatorCalls']
        require(isinstance(calls, list) and len(calls) == 37, 'complete 37 allocator calls required')
        previous = -1
        identity = None
        for index, sample in enumerate(calls):
            protocol.validate_allocator_sample(sample, index)
            require(set(sample) == SAMPLE_FIELDS, 'allocator sample must contain only fixed scalar metadata')
            integer(sample['sequence'], 'allocator sequence')
            require(previous <= sample['startUs'], 'allocator call timestamps overlap or move backwards')
            previous = sample['endUs']
            require(type(sample['sizeTBytes']) is int and sample['sizeTBytes'] in (4, 8),
                    'allocator size_t metadata invalid')
            structure = sample['mallinfo2StructBytes']
            require(structure is None or (type(structure) is int and structure == 10 * sample['sizeTBytes']),
                    'allocator structure size metadata invalid')
            version = sample['glibcVersion']
            require(version is None or (isinstance(version, str) and len(version) <= 32
                    and re.fullmatch(r'[0-9]+\.[0-9]+', version)), 'allocator libc version metadata invalid')
            if sample['status'] == 'available':
                require(version is not None, 'available allocator lacks libc version')
            else:
                require(sample['reason'] == 'unsupported-build-headers' or structure is not None,
                        'supported build headers lack allocator ABI metadata')
            current = tuple(sample[key] for key in ('status', 'reason', 'sizeTBytes',
                                                    'mallinfo2StructBytes', 'glibcVersion'))
            require(identity is None or current == identity,
                    'allocator support or ABI identity changed within one process')
            identity = current
            for value in sample['fields'].values():
                require(value is None or value <= 2 ** (8 * sample['sizeTBytes']) - 1,
                        'allocator value exceeds official size_t width')
        require(calls[0] == self.report['allocatorInitialization'],
                'initial allocator call differs from initialization')
        endpoints = self.report['externalEndpoints']
        require(calls[0]['endUs'] <= endpoints[0]['dartTimeUs'],
                'allocator initialization must precede hello and baseline')
        previous_ack = calls[0]['endUs']
        for endpoint in endpoints:
            # Equality alone accepts bool as 0/1; request metadata is integer-only.
            for key, minimum in (('sequence', 0), ('hostPid', 1), ('cycle', -1), ('dartTimeUs', 0)):
                integer(endpoint[key], 'request metadata ' + key, minimum)
            if protocol.allocator_boundary(endpoint['phase']):
                require(previous_ack <= endpoint['allocatorBefore']['startUs'],
                        'allocator boundary call overlaps the preceding endpoint')
            previous_ack = endpoint['acknowledgedDartTimeUs']
        descriptor = self.report['allocatorJournal']
        require(set(descriptor) == {'file', 'bytes', 'sha256', 'count'},
                'allocator raw journal descriptor differs')
        self.scan_retention(descriptor, 'native-retention-probes.jsonl', 37,
                            lambda row, index: require(row == calls[index],
                                'allocator report differs from raw journal'))

    def validate_categories(self):
        descriptor = self.external['retentionCategories']
        require(set(descriptor) == {'file', 'bytes', 'sha256', 'count', 'complete', 'rawAddressesOrPaths'}
                and descriptor['complete'] is True and descriptor['rawAddressesOrPaths'] is False,
                'retention category journal incomplete or unsafe metadata')
        endpoints = [point for point in self.report['externalEndpoints']
                     if protocol.allocator_boundary(point['phase'])]
        require(len(endpoints) == 18, '18 matched category endpoint pairs required')
        previous_end = -1
        category_ends = {}

        def consume(row, index):
            nonlocal previous_end
            endpoint = endpoints[index]
            require(set(row) == CATEGORY_FIELDS, 'category row must contain only fixed scalar metadata')
            require(row == endpoint['mappingCategories'], 'category report differs from raw journal')
            require(row['schema'] == 'abc.native-retention-categories.v1'
                    and integer(row['sequence'], 'category sequence') == index
                    and integer(row['externalOsSequence'], 'category external sequence') == endpoint['os']['sequence']
                    and row['phase'] == endpoint['phase'], 'category sequence or endpoint identity differs')
            require(row['metadata'] == {**{key: endpoint[key] for key in REQUEST_FIELDS},
                                       'controlArm': ARM}, 'category metadata differs from Dart request')
            require(row['clockDomain'] == PYTHON_CLOCK and row['atomic'] is False,
                    'category clock or atomicity differs')
            start = integer(row['startNs'], 'category start', 1)
            end = integer(row['endNs'], 'category end', 1)
            require(previous_end <= start <= end and endpoint['os']['smapsEndNs'] <= start,
                    'category read must follow original OS observation in Python clock')
            previous_end = end
            category_ends[row['externalOsSequence'] + 1] = end
            for field in CATEGORY_REQUIRED:
                integer(row[field], field)
            for field in CATEGORY_OPTIONAL:
                if row[field] is not None:
                    integer(row[field], field)

        self.scan_retention(descriptor, 'native-retention-categories.jsonl', 18, consume)
        # The sampler lock spans original point + category read. The next OS
        # row must follow it. No Python timestamp is compared with a Dart one.
        with (self.external_root / self.external['file']).open('rb') as stream:
            for line in stream:
                row = strict_json(line)
                if row['sequence'] in category_ends:
                    require(category_ends.pop(row['sequence']) <= row['timeNs'],
                            'category read overlaps next external OS observation')
        require(not category_ends, 'category observation lacks its following external OS row')

    def validate_external(self):
        """Stream one owned PID; only small acknowledged endpoint rows are kept."""
        manifest, endpoints = self.external, self.report['externalEndpoints']
        require(manifest['schema'] == 'abc.memory-probe-control-os-manifest.v1', 'unknown external OS schema')
        require(manifest['status'] == 'completed' and manifest['complete'] is True
                and manifest.get('failure') is None, 'external failure or partial sampler cannot pass')
        require(manifest['arm'] == ARM and manifest['baseProductCommit'] == PRODUCT_COMMIT
                and manifest['processInvocations'] == 1 and manifest['ownedProcess'] is True
                and manifest['endpointRequests'] == 79, 'external owned-process control descriptor differs')
        require(self.report['externalOs'] == manifest, 'report/external sampler manifests differ')
        require(manifest['clockDomain'] == PYTHON_CLOCK and manifest['timeUnit'] == 'nanoseconds'
                and manifest['crossClockSubtractionAllowed'] is False, 'external clock domains not explicit')
        require(manifest['targetStatusIntervalNs'] == 10_000_000
                and manifest['targetSmapsIntervalNs'] == 100_000_000, 'external target cadence differs')
        require(manifest['integrityScope'] == 'successfully-flushed-rows', 'external integrity scope differs')
        identity = manifest['processIdentity']
        require(identity['pid'] == self.report['hostPid'], 'external sampler selected another PID')
        for key in ('pid', 'processGroupId', 'starttimeTicks', 'groupLeaderStarttimeTicks',
                    'runnerPid', 'runnerStarttimeTicks'):
            integer(identity[key], f'external process {key}', 1)
        integer(identity['uid'], 'external process UID')
        require(identity['pid'] != identity['runnerPid'] and identity['processGroupId'] != identity['runnerPid'],
                'external sampler is not a distinct runner-owned process group')
        require(len(endpoints) == 79 and [(p['cycle'], p['phase'], p['kind']) for p in endpoints] == endpoint_plan(),
                'all 79 ordered external protocol endpoints required')
        wanted, previous_ack = {}, -1
        for sequence, endpoint in enumerate(endpoints):
            require(endpoint['sequence'] == sequence and endpoint['hostPid'] == identity['pid'],
                    'external request sequence or PID differs')
            at = integer(endpoint['dartTimeUs'], 'endpoint Dart request time')
            ack = integer(endpoint['acknowledgedDartTimeUs'], 'endpoint Dart acknowledgement time')
            require(previous_ack <= at <= ack, 'external endpoint Dart request/acknowledgement order invalid')
            previous_ack = ack
            sample_sequence = integer(endpoint['os']['sequence'], 'external raw sample sequence')
            require(sample_sequence not in wanted, 'external endpoints reuse one OS raw sample')
            wanted[sample_sequence] = endpoint
        name = manifest['file']
        require(isinstance(name, str) and Path(name).name == name and name.endswith('.jsonl'),
                'unsafe external raw filename')
        path = self.external_root / name
        require(path.is_file() and not path.is_symlink(), 'external raw file missing or symbolic link')
        require(path.resolve() not in {(self.root / file).resolve() for file in self.files},
                'external and in-process raw files cannot be the same')
        hasher, byte_count, count, smaps_count, periodic = hashlib.sha256(), 0, 0, 0, 0
        previous_end = previous_start = first = None
        maximum_gap = 0
        seen = set()
        with path.open('rb') as stream:
            for line in stream:
                require(line.endswith(b'\n'), 'external raw JSONL line incomplete')
                hasher.update(line)
                byte_count += len(line)
                row = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                require(isinstance(row, dict), 'external raw object required')
                require(row['schema'] == 'abc.memory-probe-control-os.v1' and row['type'] == 'os'
                        and integer(row['sequence'], 'external sequence') == count,
                        'external raw sequence dropped, repeated or reordered')
                require(row['pid'] == identity['pid'] and row['starttimeTicks'] == identity['starttimeTicks'],
                        'external raw identity differs (possible PID reuse)')
                require(row['clockDomain'] == PYTHON_CLOCK and row['timeUnit'] == 'nanoseconds'
                        and row['atomic'] is False, 'external raw clock or atomicity differs')
                at, end = integer(row['timeNs'], 'external time', 1), integer(row['statusEndNs'], 'external status end', 1)
                require(at <= end and (previous_end is None or at >= previous_end),
                        'external OS timestamp order invalid')
                if first is None:
                    first = at
                if previous_start is not None:
                    maximum_gap = max(maximum_gap, at - previous_start)
                previous_start, previous_end = at, end
                for field in original.OS_FIELDS[:2]:
                    integer(row[field], field, 1)
                require(row['rssBytes'] <= row['processVmHwmBytes'], 'external HWM below RSS')
                smaps_fields = ('smapsTimeNs', 'smapsEndNs', *original.OS_FIELDS[2:],
                                'privateCleanBytes', 'privateDirtyBytes', 'privateHugetlbBytes',
                                'ussIncludesPrivateHugetlb')
                if 'smapsTimeNs' in row:
                    a, b = integer(row['smapsTimeNs'], 'external smaps start', 1), integer(row['smapsEndNs'], 'external smaps end', 1)
                    require(end <= a <= b, 'external status/smaps brackets invalid')
                    previous_end = b
                    for field in (*original.OS_FIELDS[2:], 'privateCleanBytes', 'privateDirtyBytes'):
                        integer(row[field], field)
                    huge = row['privateHugetlbBytes']
                    if huge is not None:
                        integer(huge, 'private huge pages')
                    require(row['ussIncludesPrivateHugetlb'] is (huge is not None), 'external huge-page availability differs')
                    require(row['ussBytes'] == row['privateCleanBytes'] + row['privateDirtyBytes'] + (huge or 0),
                            'external USS components differ')
                    smaps_count += 1
                else:
                    require(not any(key in row for key in smaps_fields), 'partially absent external smaps fields')
                    require(row['phase'] == 'periodic', 'named external endpoint lacks smaps observation')
                if count == 0:
                    require(row['phase'] == 'sampler-start' and 'metadata' not in row,
                            'external sampler-start row missing')
                elif row['phase'] == 'periodic':
                    require('metadata' not in row, 'periodic sample has endpoint metadata')
                    periodic += 1
                else:
                    require(count in wanted, 'unacknowledged or unknown external endpoint row')
                    endpoint = wanted[count]
                    require(endpoint['os'] == row, 'external acknowledged OS row differs from raw journal')
                    require(row['phase'] == endpoint['phase']
                            and row['metadata'] == {**{key: endpoint[key] for key in REQUEST_FIELDS},
                                                   'controlArm': ARM},
                            'external raw metadata differs from Dart request')
                    require(row['metadataClockDomains'] == {'dartTimeUs': DART_CLOCK},
                            'Dart metadata clock must remain distinct from Python sampler clock')
                    seen.add(count)
                count += 1
        require(hasher.hexdigest() == sha(manifest['sha256']) and byte_count == manifest['bytes'],
                'external raw bytes/SHA-256 mismatch')
        require(count == manifest['statusSamples'] and smaps_count == manifest['smapsSamples']
                and len(seen) == manifest['namedPointSamples'] == len(endpoints) and seen == set(wanted),
                'external sample, smaps or acknowledged endpoint totals differ')
        require(periodic > 0 and first == manifest['firstTimeNs'] and previous_start == manifest['lastTimeNs']
                and maximum_gap == manifest['maximumObservedStatusGapNs'],
                'external periodic observations or timing summary differs')
        integer(manifest['missedPeriodicStatusTicks'], 'missed periodic external ticks')
        self.validate_endpoint_boundaries(endpoints)
        self.external_summary = {
            'file': name, 'sha256': manifest['sha256'], 'bytes': byte_count,
            'clockDomain': PYTHON_CLOCK, 'correlationClockDomain': DART_CLOCK,
            'crossClockSubtractionAllowed': False, 'processIdentity': identity,
            'statusSamples': count, 'periodicSamples': periodic, 'smapsSamples': smaps_count,
            'acknowledgedEndpoints': len(seen), 'maximumObservedStatusGapNs': maximum_gap,
            'missedPeriodicStatusTicks': manifest['missedPeriodicStatusTicks'],
            'endpoints': [{'cycle': point['cycle'], 'phase': point['phase'],
                           'sequence': point['sequence'], 'osSequence': point['os']['sequence'],
                           'pythonTimeNs': point['os']['timeNs'], 'dartRequestUs': point['dartTimeUs'],
                           'dartAcknowledgedUs': point['acknowledgedDartTimeUs'],
                           **metrics(point['os'])} for point in endpoints],
        }

    def summarize_retention(self):
        calls = self.report['allocatorCalls']
        selected = [endpoint for endpoint in self.report['externalEndpoints']
                    if protocol.allocator_boundary(endpoint['phase'])]
        supported = all(call['status'] == 'available' for call in calls)
        semantics = supported and all(call['glibcVersion'] in INSPECTED_GLIBC for call in calls)
        categories = all(endpoint['mappingCategories'][field] is not None for endpoint in selected
                         for field in CATEGORY_OPTIONAL[:3])
        reasons = []
        if not supported:
            reasons.append('allocator observation unsupported; explicit null fields retained')
        elif not semantics:
            reasons.append('runtime glibc version was not inspected; allocator semantics unverified')
        if not categories:
            reasons.append('one or more optional PSS mapping categories unavailable')
        self.attribution_available = not reasons
        self.availability_reasons = reasons
        released = {endpoint['cycle']: endpoint for endpoint in selected
                    if endpoint['phase'] == 'released-quiet.end'}
        pairs = []
        for cycle in range(4):
            earlier, later = released[cycle], released[cycle + 4]
            pairs.append({'cycles': [cycle, cycle + 4],
                          'mode': self.report['cycles'][cycle]['mode'],
                          'scenario': self.report['cycles'][cycle]['scenario'],
                          'allocatorBeforeDelta': original.difference(later['allocatorBefore']['fields'],
                                                                      earlier['allocatorBefore']['fields']),
                          'allocatorAfterDelta': original.difference(later['allocatorAfter']['fields'],
                                                                     earlier['allocatorAfter']['fields']),
                          'mappingCategoryDelta': original.difference(
                              {key: later['mappingCategories'][key] for key in CATEGORY_OPTIONAL + CATEGORY_REQUIRED},
                              {key: earlier['mappingCategories'][key] for key in CATEGORY_OPTIONAL + CATEGORY_REQUIRED})})
        self.retention_summary = {
            'allocatorCalls': len(calls), 'matchedBoundaryPairs': len(selected),
            'initialization': self.report['allocatorInitialization'],
            'endpoints': [{'cycle': endpoint['cycle'], 'phase': endpoint['phase'],
                           'allocatorBefore': endpoint['allocatorBefore'],
                           'allocatorAfter': endpoint['allocatorAfter'],
                           'mappingCategories': endpoint['mappingCategories']}
                          for endpoint in selected],
            'sameVariantPairs': pairs, 'rawJournals': self.retention_files,
            'inspectedGlibcVersions': sorted(INSPECTED_GLIBC),
            'runtimeSemanticsVerified': semantics,
            'distributionPatchSemanticsVerified': False,
        }
        return self.retention_summary

    def run(self):
        for name, method in (
                ('report', self.validate_header), ('provenance', self.validate_provenance),
                ('boundaries', self.validate_boundaries), ('cycles', self.validate_cycles),
                ('frames', self.validate_frames), ('records', self.validate_records),
                ('in-process OS', self.validate_os), ('schedule', self.validate_schedule),
                ('checkpoints', self.validate_points), ('external OS', self.validate_external),
                ('allocator raw', self.validate_allocator), ('category raw', self.validate_categories)):
            self.guard(name, method)
        extra = self.guard('raw inventory', lambda: sorted(path.name for path in self.root.glob('*.jsonl')
                                                          if path.name not in self.files))
        if extra:
            self.errors.append(f'Unreferenced in-process raw JSONL files: {extra}')
        windows = self.guard('window attribution', self.attribute_windows)
        measurements = self.guard('OS measurements', self.summarize)
        retention = self.guard('retention measurements', self.summarize_retention)
        valid = not self.errors
        available = valid and self.attribution_available
        return {
            'schema': SCHEMA, 'status': ('failed' if not valid else
                'validated-retention-observation' if available else 'unsupported-inconclusive'),
            'evidenceValid': valid, 'acceptanceEvidence': False, 'plateauEstablished': False,
            'improvementEstablished': False, 'memoryImprovementEstablished': False,
            'allocatorAttributionAvailable': available, 'causalAttribution': 'unresolved',
            'originalGrowthStillUnresolved': True, 'arm': ARM,
            'expectedCommit': self.expected_commit, 'baseProductCommit': PRODUCT_COMMIT,
            'hostPid': self.report.get('hostPid'), 'reportedStatus': self.report.get('status'),
            'reportedFailure': self.report.get('failure'), 'reportedFailureStack': self.report.get('failureStack'),
            'errors': self.errors, 'warnings': self.warnings,
            'attribution': {'available': available,
                            'scope': 'allocator-accounting-and-OS-category-description-only',
                            'ownershipEstablished': False,
                            'reasons': self.availability_reasons if valid else ['evidence validation failed']},
            'measurements': measurements, 'retention': retention, 'externalOs': self.external_summary,
            'topology': {'nativeWorkersExpected': self.report.get('expectedNativeWorkers'),
                         'inProcessOsSamplerRetained': self.report.get('inProcessOsSamplerRetained'),
                         'externalOsSamplerEnabled': self.report.get('externalOsSamplerEnabled'),
                         'vmProbeCalls': self.report.get('vmProbeCalls'), 'heapFieldsMeasured': False},
            'raw': {'verifiedOrInspectedFiles': self.files, 'receivedFrameCount': self.frame_count,
                    'uniqueEngineFrameNumbers': len(self.engine_frames), 'duplicateEngineFrameRecords': self.duplicate_count,
                    'lateReceivedFramesByBoundary': dict(self.late_boundaries),
                    'frameCycleAttribution': dict(self.frame_classification), 'windowAttribution': windows,
                    'inProcessOsSamples': self.os_count, 'inProcessPeriodicSamples': self.os_periodic,
                    'inProcessSmapsSamples': self.os_smaps, 'inProcessOsMaxima': self.os_maxima,
                    'recordCounts': {kind: len(rows) for kind, rows in self.records.items()},
                    'allReceivedRecordsReconciled': valid, 'engineUnemittedTimingCompleteness': 'unknown'},
            'limits': [
                'All eight cycles, startup, cancellation, outliers and final tail are retained.',
                'Cycles 0–3 are first-use variants; 4–7 repeat each once. This cannot establish a plateau.',
                'uordblks is allocator-accounted in-use, including possible freed tcache blocks and metadata; it is not application-live bytes.',
                'fordblks is allocator free arena space; arena and hblkhd are separate virtual accounting, not resident totals.',
                'Allocator and OS reads are separate, non-atomic observations. Neither is subtracted from RSS or summed with overlapping views.',
                'OS mapping categories cannot identify a Dart, engine, graphics or other native owner.',
                'The inspected upstream glibc family does not verify every distribution patch.',
                'Python monotonic_ns and Dart Timeline.now are distinct clock domains; their timestamps are never subtracted.',
                'Only callbacks received before recordingStoppedUs are reconciled; engine-unemitted timings remain unknown.',
                'No VM memory probes, forced GC, trim, allocator tuning, leak threshold or FPS certification is introduced.',
            ],
        }


def validate(report, raw_directory, build, expected_commit, build_sha256, external,
             external_directory, source=None, derivation=None, helper_build=None):
    return RetentionValidator(report, raw_directory, build, expected_commit, build_sha256,
                              external, external_directory, source, derivation, helper_build).run()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--raw-directory', required=True, type=Path)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--external-os', required=True, type=Path)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    options = parser.parse_args(argv)
    try:
        require(options.report.parent.resolve() == options.external_os.parent.resolve(),
                'external and retention evidence must share the report directory')
        result = validate(load_json(options.report), options.raw_directory, load_json(options.build),
                          options.expected_commit, digest(options.build), load_json(options.external_os),
                          options.report.parent)
        result['inputs'] = {name: {'file': path.name, 'sha256': digest(path)}
                            for name, path in (('report', options.report), ('build', options.build),
                                               ('externalOs', options.external_os))}
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, OverflowError) as error:
        result = {'schema': SCHEMA, 'status': 'failed', 'evidenceValid': False, 'acceptanceEvidence': False,
                  'plateauEstablished': False, 'improvementEstablished': False,
                  'memoryImprovementEstablished': False, 'allocatorAttributionAvailable': False,
                  'originalGrowthStillUnresolved': True, 'attribution': {'available': False},
                  'errors': [str(error)]}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(f'{result["status"]}: {len(result.get("errors", []))} validation error(s); {options.output}')
    return 0 if result['evidenceValid'] else 1


if __name__ == '__main__':
    sys.exit(main())
