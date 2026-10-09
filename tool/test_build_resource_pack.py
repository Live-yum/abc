"""Synthetic fixtures only. No game content or external dependencies."""
import copy
import gzip
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('builder', Path(__file__).with_name('build_resource_pack.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuilderTest(unittest.TestCase):
    def world_rule_presets(self):
        self.write('synthetic/rules.mjs', b'throw Error("must never execute");')
        return {'schema': 1, 'gameVersion': 'synthetic-1',
                'sourceFiles': {'synthetic/rules.mjs': builder.sha((self.root / 'synthetic/rules.mjs').read_bytes())},
                'entries': [{'id': 'synthetic-preset', 'name': 'Synthetic preset',
                             'badge': 'Synthetic', 'description': 'Conditional source fixture',
                             'builtinMode': 'purify', 'rules': [
                                 {'where': {'is_active': 1, 'exclude_biome_region': 3},
                                  'patch': {'terrain_theme': 1}, 'limit': 4},
                                 {'where': {'has_wall': True, 'biome_region': 2},
                                  'patch': {'invisible_wall': 1}},
                             ]}]}

    def test_world_rule_presets_keep_conditions_order_and_bound_source_bytes(self):
        self.fixture()
        envelope = self.world_rule_presets()
        source = self.root / 'presets.json'
        source.write_text(json.dumps(envelope))
        output = self.root / 'presets.abcpack'
        report = builder.build(self.root, output, False, world_rule_presets=source)
        self.assertEqual(report['families']['world-rule-presets'], 1)
        data = output.read_bytes()
        length = struct.unpack('<I', data[8:12])[0]
        header = json.loads(data[12:12 + length])
        entry = next(e for e in header['entries'] if e['path'] == 'catalog/world-rule-presets.json')
        start = 12 + length + entry['offset']
        self.assertEqual(json.loads(data[start:start + entry['bytes']]), envelope['entries'])
        provenance = header['provenance']['worldRulePresets']
        self.assertEqual(provenance['sourceFiles'], envelope['sourceFiles'])
        self.assertEqual(provenance['inputSha256'], builder.sha(source.read_bytes()))
        self.assertEqual(header['provenance']['sourceObjects']['local-world-rule-presets.json'], provenance['inputSha256'])
        self.assertEqual(header['provenance']['sourceObjects']['synthetic/rules.mjs'], envelope['sourceFiles']['synthetic/rules.mjs'])
        self.write('synthetic/rules.mjs', b'changed source')
        with self.assertRaisesRegex(ValueError, 'source integrity'):
            builder.read_world_rule_presets(source, 'synthetic-1', self.root)

    def test_world_rule_presets_reject_unpinned_versions_fields_and_rule_overflow(self):
        envelope = self.world_rule_presets()
        cases = [{**envelope, key: value} for key, value in [
            ('schema', True), ('gameVersion', 'wrong'), ('sourceFiles', {}),
            ('sourceFiles', {'../outside': 'a' * 64}), ('entries', [])]]
        for key, value in [('rules', []), ('rules', envelope['entries'][0]['rules'] * 65),
                           ('builtinMode', 'guessed'), ('id', '../unsafe'), ('name', ' '),
                           ('unknown', 1)]:
            invalid = copy.deepcopy(envelope)
            invalid['entries'][0][key] = value
            cases.append(invalid)
        for side, key, value in [('where', 'terrain_theme', 1), ('patch', 'is_active', 1),
                                 ('where', 'type', True), ('where', 'type', 1.0),
                                 ('where', 'biome_region', 15), ('patch', 'terrain_theme', 4),
                                 ('where', 'is_active', 2), ('patch', 'unknown', 1)]:
            invalid = copy.deepcopy(envelope)
            invalid['entries'][0]['rules'][0][side][key] = value
            cases.append(invalid)
        for key, value in [('limit', True), ('limit', -1), ('limit', 2147483648),
                           ('unknown', 1), ('patch', {})]:
            invalid = copy.deepcopy(envelope)
            invalid['entries'][0]['rules'][0][key] = value
            cases.append(invalid)
        duplicate = copy.deepcopy(envelope)
        duplicate['entries'].append(copy.deepcopy(duplicate['entries'][0]))
        cases.append(duplicate)
        source = self.root / 'invalid-presets.json'
        for invalid in cases:
            with self.subTest(invalid=invalid):
                source.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    builder.read_world_rule_presets(source, 'synthetic-1', self.root)
        source.write_text('{"schema":1,"schema":1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            builder.read_world_rule_presets(source, 'synthetic-1', self.root)

    def test_world_rule_presets_allow_exactly_128_rules(self):
        envelope = self.world_rule_presets()
        envelope['entries'][0]['rules'] *= 64
        source = self.root / 'presets.json'
        source.write_text(json.dumps(envelope))
        rows, _ = builder.read_world_rule_presets(source, 'synthetic-1', self.root)
        self.assertEqual(len(rows[0]['rules']), 128)

    def test_conversion_profiles_require_matching_identity_and_valid_ranges(self):
        self.fixture()
        rule = {'minimum': 0, 'maximum': 2, 'fallback': 0, 'behavior': 'clamp'}
        profile = {'id': 326, 'schema': 1, 'gameVersion': 'synthetic-1',
                   'sourceCommit': '0' * 40, 'sourceFiles': ['Synthetic contract'],
                   'ranges': {key: dict(rule) for key in ('hair', 'skinVariant', 'voiceVariant')}}
        path = self.root / 'profiles.json'
        path.write_text(json.dumps(profile))
        result = builder.build(self.root, self.root / 'profile.abcpack', False, path)
        self.assertEqual(result['families']['player-conversion-profiles'], 1)
        profile['gameVersion'] = 'mismatch'
        path.write_text(json.dumps(profile))
        with self.assertRaises(ValueError):
            builder.read_conversion_profiles(path, 'synthetic-1')
        profile['gameVersion'] = 'synthetic-1'
        profile['ranges']['hair']['maximum'] = -1
        path.write_text(json.dumps(profile))
        with self.assertRaises(ValueError):
            builder.read_conversion_profiles(path, 'synthetic-1')

    def entity_markers(self):
        return {'gameVersion': 'synthetic-1', 'sourceSha256': '1' * 64, 'entries': [
            {'id': '42:first', 'name': 'First synthetic anchor',
             'selector': {'tile_type': 42, 'locate': 1, 'frame_x': 0, 'frame_y': 0}},
            {'id': '42:second', 'name': 'Second synthetic anchor',
             'selector': {'tile_type': 42, 'locate': 1, 'frame_x': 18, 'frame_y': 0}},
        ]}

    def test_entity_markers_preserve_variants_and_provenance(self):
        self.fixture()
        envelope = self.entity_markers()
        source = self.root / 'entity-markers.json'
        source.write_text(json.dumps(envelope))
        output = self.root / 'entities.abcpack'
        report = builder.build(self.root, output, False, entity_markers=source)
        self.assertEqual(report['families']['entity-markers'], 2)
        data = output.read_bytes()
        length = struct.unpack('<I', data[8:12])[0]
        header = json.loads(data[12:12 + length])
        entry = next(e for e in header['entries'] if e['path'] == 'catalog/entity-markers.json')
        start = 12 + length + entry['offset']
        self.assertEqual(json.loads(data[start:start + entry['bytes']]), envelope['entries'])
        provenance = header['provenance']['sourceObjects']
        self.assertEqual(provenance['local-entity-markers.json'], builder.sha(source.read_bytes()))
        self.assertEqual(provenance['entity-markers-source'], envelope['sourceSha256'])

    def test_entity_markers_reject_bad_versions_fields_and_duplicate_selectors(self):
        envelope = self.entity_markers()
        cases = []
        for field, value in [('gameVersion', 'wrong'), ('sourceSha256', 'unverified'), ('entries', [])]:
            cases.append({**envelope, field: value})
        for field, value in [('tile_type', -1), ('tile_type', 65536), ('locate', 0), ('locate', 3),
                             ('frame_x', -2), ('frame_y', 32768), ('frame_x_mod', -1),
                             ('frame_y_mod', 32768), ('frame_x', True), ('extra', 1)]:
            invalid = copy.deepcopy(envelope)
            invalid['entries'][0]['selector'][field] = value
            cases.append(invalid)
        duplicate = copy.deepcopy(envelope)
        duplicate['entries'][1]['selector'] = duplicate['entries'][0]['selector']
        cases.append(duplicate)
        duplicate_id = copy.deepcopy(envelope)
        duplicate_id['entries'][1]['id'] = duplicate_id['entries'][0]['id']
        cases.append(duplicate_id)
        source = self.root / 'invalid-entities.json'
        for invalid in cases:
            with self.subTest(invalid=invalid):
                source.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    builder.read_entity_markers(source, 'synthetic-1')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, data):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def object(self, value):
        plain = builder.encode(value)
        data = gzip.compress(plain)
        digest = builder.sha(data)
        path = f'objects/{digest[:2]}/{digest}.json.gz'
        self.write(f'features/builtin-resources/pages/resources/{digest}.json.gz', data)
        return {'path': path, 'sha256': digest, 'bytes': len(data), 'encoding': 'gzip', 'decodedBytes': len(plain)}

    def fixture(self):
        descriptor = {'schema': 1, 'gameVersion': 'synthetic-1', 'textures': self.object({}), 'families': {
            'item-index': [{'object': self.object([{'id': 103, 'name': 'Synthetic', 'maxStack': 5, 'research': 2, 'persistentId': 'Synthetic'}])}],
            'items': [{'object': self.object([{'id': 103, 'gameplay': {'ammo': 1}, 'eligiblePrefixes': [3]}])}],
            'tiles': [{'object': self.object([{'id': '42:7', 'type': 42, 'variant': 7}])}],
        }}
        descriptor['rgb'] = {'stableCandidates': self.object([[0, 42, 7, 0, 12, 34, 56, 1]])}
        self.write('features/fusion/vendor/circuit/actuation-data.mjs', b'export default Object.freeze({"tileFrameImportant":[21]});')
        self.write('features/fusion/render/vendor/exploreTV/overview-frame-recipes.mjs', b'export const ORDINARY_BLOCKS = Object.freeze([42]);')
        self.write('features/fusion/assets/packaged-textures.mjs', b'export default {"schema":1,"gameVersion":"synthetic-1","textures":{}};')
        self.write('infrastructure/assets/builtin-descriptor.json', builder.encode(descriptor))
        self.write('features/achievements/pages/services/catalog.mjs', b'export const ACHIEVEMENT_CATALOG = {"SYNTHETIC":{"name":"Test", "conditions":[]}};\nthrow Error("must not execute");')
        return descriptor

    def test_roundtrip_merges_without_renumbering(self):
        self.fixture()
        output = self.root / 'test.abcpack'
        report = builder.build(self.root, output, include_icons=False)
        self.assertEqual(report['families']['items'], 1)
        self.assertEqual(report['families']['research'], 1)
        data = output.read_bytes()
        length = struct.unpack('<I', data[8:12])[0]
        header = json.loads(data[12:12 + length])
        entry = next(e for e in header['entries'] if e['path'] == 'catalog/items.json')
        start = 12 + length + entry['offset']
        row = json.loads(data[start:start + entry['bytes']])[0]
        self.assertEqual(row['id'], 103)
        self.assertEqual(row['eligiblePrefixes'], [3])
        self.assertEqual(row['persistentId'], 'Synthetic')
        self.assertEqual(row['maxStack'], 5)

    def test_does_not_overwrite_existing_output(self):
        self.fixture()
        output = self.root / 'existing'
        output.write_text('keep')
        with self.assertRaises(FileExistsError):
            builder.build(self.root, output, include_icons=False)
        self.assertEqual(output.read_text(), 'keep')

    def test_corrupt_source_rejected(self):
        descriptor = self.fixture()
        ref = descriptor['families']['items'][0]['object']
        self.write('features/builtin-resources/pages/resources/' + Path(ref['path']).name, b'broken')
        with self.assertRaises(ValueError):
            builder.build(self.root, self.root / 'out', include_icons=False)
        self.assertFalse((self.root / 'out').exists())

    def test_unsafe_paths_and_symlinks_rejected(self):
        for path in ['../private', '/etc/passwd', 'C:\\file']:
            with self.assertRaises(ValueError):
                builder.local_read(self.root, path)
        (self.root / 'target').write_text('synthetic')
        (self.root / 'link').symlink_to(self.root / 'target')
        with self.assertRaises(ValueError):
            builder.local_read(self.root, 'link')

    def test_bounded_gzip_and_trailing_stream(self):
        data = gzip.compress(b'x' * 10000)
        for size in [1, 9999, 10001, -1, builder.MAX_FILE + 1]:
            with self.assertRaises(ValueError):
                builder.decode_gzip(data, size)
        self.assertEqual(builder.decode_gzip(data, 10000), b'x' * 10000)
        with self.assertRaises(ValueError):
            builder.decode_gzip(data + gzip.compress(b'other'), 10000)


if __name__ == '__main__':
    unittest.main()
