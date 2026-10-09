#!/usr/bin/env python3
"""Build a PRIVATE local ABCPACK1 from resources the caller is authorized to use.

No downloads, JavaScript execution, archive extraction, or repository writes.
Only the original builder belongs in source control. Never publish its output
unless you independently hold redistribution rights to every contained asset.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import zlib

MAX_PACK = 256 * 1024 * 1024
MAX_META = 64 * 1024 * 1024
MAX_FILE = 64 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def local_read(root, relative, limit=MAX_FILE):
    path = PurePosixPath(relative)
    if path.is_absolute() or any(p in ('..', '.', '') for p in path.parts) or '\\' in relative or ':' in relative:
        raise ValueError('Unsafe source path')
    target = root.joinpath(*path.parts)
    # Explicitly refuse symlinks, including parent symlinks, within source root.
    current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('Symlink source is not supported')
    if not target.is_file() or target.stat().st_size > limit:
        raise ValueError(f'Missing or oversized source: {relative}')
    return target.read_bytes()


def decode_gzip(data, size):
    if not isinstance(size, int) or not 0 < size <= MAX_FILE:
        raise ValueError('Invalid decoded size')
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    plain = decoder.decompress(data, size + 1)
    if len(plain) != size or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError('Invalid or oversized gzip object')
    return plain


def read_conversion_profiles(path, game_version):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError('Invalid conversion profile file')
    data = path.read_bytes()
    profiles = json.loads(data)
    if isinstance(profiles, dict):
        profiles = [profiles]
    if not isinstance(profiles, list) or not 1 <= len(profiles) <= 289:
        raise ValueError('Invalid conversion profile list')
    seen = set()
    for profile in profiles:
        if not isinstance(profile, dict) or profile.get('schema') != 1 or profile.get('gameVersion') != game_version:
            raise ValueError('Conversion profile version mismatch')
        version = profile.get('id')
        if type(version) is not int or not 38 <= version <= 326 or version in seen:
            raise ValueError('Invalid or duplicate conversion profile version')
        seen.add(version)
        commit = profile.get('sourceCommit')
        sources = profile.get('sourceFiles')
        if not isinstance(commit, str) or not re.fullmatch(r'[a-f0-9]{40}', commit) or not isinstance(sources, list) or not sources:
            raise ValueError('Conversion profile requires pinned source provenance')
        ranges = profile.get('ranges', {})
        if not isinstance(ranges, dict):
            raise ValueError('Invalid conversion profile ranges')
        for field in ('hair', 'skinVariant', 'voiceVariant'):
            rule = ranges.get(field, {})
            if not isinstance(rule, dict):
                raise ValueError('Invalid conversion profile range')
            values = [rule.get(k) for k in ('minimum', 'maximum', 'fallback')]
            if any(type(v) is not int for v in values) or not 0 <= values[0] <= values[2] <= values[1] <= 2147483647:
                raise ValueError('Invalid conversion profile range')
            if rule.get('behavior') not in ('clamp', 'resetAbove'):
                raise ValueError('Unsupported conversion profile normalization')
    return profiles, sha(data)


def read_entity_markers(path, game_version):
    """Read an explicit private JSON catalog; never derive frames from map variants."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError('Invalid entity marker file')
    data = path.read_bytes()
    envelope = json.loads(data)
    if not isinstance(envelope, dict) or set(envelope) != {'gameVersion', 'sourceSha256', 'entries'}:
        raise ValueError('Invalid entity marker envelope')
    if envelope['gameVersion'] != game_version:
        raise ValueError('Entity marker game version mismatch')
    source_sha = envelope['sourceSha256']
    if not isinstance(source_sha, str) or not re.fullmatch(r'[a-f0-9]{64}', source_sha):
        raise ValueError('Entity markers require pinned source provenance')
    rows = envelope['entries']
    if not isinstance(rows, list) or not 1 <= len(rows) <= 50000:
        raise ValueError('Invalid entity marker list')
    ids, selectors = set(), set()
    bounds = {'tile_type': (0, 65535), 'locate': (1, 2),
              'frame_x': (-1, 32767), 'frame_y': (-1, 32767),
              'frame_x_mod': (0, 32767), 'frame_y_mod': (0, 32767)}
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'id', 'name', 'selector'}:
            raise ValueError('Invalid entity marker row')
        key, name, selector = row['id'], row['name'], row['selector']
        if not isinstance(key, str) or not 1 <= len(key) <= 128 or key in ids:
            raise ValueError('Invalid or duplicate entity marker ID')
        ids.add(key)
        if not isinstance(name, str) or not name.strip() or len(name) > 512:
            raise ValueError('Invalid entity marker name')
        if not isinstance(selector, dict) or not {'tile_type', 'locate'} <= set(selector) or not set(selector) <= set(bounds):
            raise ValueError('Invalid entity marker selector fields')
        for field, value in selector.items():
            minimum, maximum = bounds[field]
            if type(value) is not int or not minimum <= value <= maximum:
                raise ValueError('Entity marker selector out of range')
        x, y = selector.get('frame_x', -1), selector.get('frame_y', -1)
        identity = (selector['tile_type'], selector['locate'], x, y,
                    selector.get('frame_x_mod', 0) if x >= 0 else 0,
                    selector.get('frame_y_mod', 0) if y >= 0 else 0)
        if identity in selectors:
            raise ValueError('Duplicate entity marker selector')
        selectors.add(identity)
    return rows, sha(data), source_sha


def read_world_rule_presets(path, game_version, root):
    """Validate caller-extracted literal rules and their exact local source bytes.

    This reader never evaluates JavaScript or guesses an expansion of a native
    biome mode. The optional input and the resulting catalog remain private.
    """
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError('Invalid world rule preset file')
    data = path.read_bytes()

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate world rule preset JSON key')
            result[key] = value
        return result

    def reject_constant(value):
        raise ValueError('Non-finite world rule preset value')

    envelope = json.loads(data, object_pairs_hook=unique_object, parse_constant=reject_constant)
    if (not isinstance(envelope, dict) or
            set(envelope) != {'schema', 'gameVersion', 'sourceFiles', 'entries'} or
            type(envelope['schema']) is not int or envelope['schema'] != 1):
        raise ValueError('Invalid world rule preset envelope')
    if envelope['gameVersion'] != game_version:
        raise ValueError('World rule preset game version mismatch')
    sources = envelope['sourceFiles']
    if not isinstance(sources, dict) or not 1 <= len(sources) <= 16:
        raise ValueError('World rule presets require pinned source files')
    for relative, digest in sources.items():
        if (not isinstance(relative, str) or not relative or len(relative) > 512 or
                any(part in ('', '.', '..') for part in relative.split('/')) or
                not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest)):
            raise ValueError('Invalid world rule preset source provenance')
        if sha(local_read(root, relative)) != digest:
            raise ValueError(f'World rule preset source integrity failure: {relative}')

    boolean_fields = {'is_active', 'has_wall', 'wire_red', 'wire_blue', 'wire_green',
                      'wire_yellow', 'actuator', 'inactive', 'invisible_block',
                      'invisible_wall', 'fullbright_block', 'fullbright_wall'}
    bounds = {'type': (0, 65535), 'wall': (0, 65535),
              'biome_region': (1, 14), 'exclude_biome_region': (1, 14),
              'terrain_theme': (1, 3), 'wall_theme': (1, 3), 'furniture_theme': (1, 3),
              'platform_style': (0, 69), 'frame_x': (0, 32767), 'frame_y': (0, 32767),
              'liquid_amount': (0, 255), 'liquid_type': (0, 4), 'brick_style': (0, 5),
              'tile_color': (0, 30), 'wall_color': (0, 30)}
    where_only = {'is_active', 'has_wall', 'biome_region', 'exclude_biome_region'}
    patch_only = {'terrain_theme', 'wall_theme', 'furniture_theme'}

    def integer(value, minimum, maximum):
        return type(value) is int and minimum <= value <= maximum

    def material(value):
        keys = {'frame_x', 'frame_y', 'width', 'height', 'coordinate_width',
                'padding', 'coordinate_heights'}
        if not isinstance(value, dict) or set(value) != keys:
            raise ValueError('Invalid world rule preset material')
        for key, low, high in [('frame_x', 0, 32767), ('frame_y', 0, 32767),
                               ('width', 1, 32), ('height', 1, 32),
                               ('coordinate_width', 1, 32767), ('padding', 0, 32767)]:
            if not integer(value[key], low, high):
                raise ValueError('World rule preset material out of range')
        heights = value['coordinate_heights']
        stride = value['coordinate_width'] + value['padding']
        if (not isinstance(heights, list) or len(heights) != value['height'] or
                stride > 32767 or value['frame_x'] + (value['width'] - 1) * stride > 32767):
            raise ValueError('World rule preset material layout exceeds bounds')
        y = value['frame_y']
        for height in heights:
            if not integer(height, 1, 32767) or y > 32767:
                raise ValueError('World rule preset material height out of range')
            y += height + value['padding']

    rows, ids, modes = envelope['entries'], set(), set()
    if not isinstance(rows, list) or not 1 <= len(rows) <= 128:
        raise ValueError('Invalid world rule preset list')
    for row in rows:
        required = {'id', 'name', 'badge', 'description', 'rules'}
        if (not isinstance(row, dict) or not required <= set(row) or
                not set(row) <= required | {'builtinMode'}):
            raise ValueError('Invalid world rule preset row')
        key = row['id']
        if not isinstance(key, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,127}', key) or key in ids:
            raise ValueError('Invalid or duplicate world rule preset ID')
        ids.add(key)
        for field, size in [('name', 160), ('badge', 80), ('description', 2000)]:
            value = row[field]
            if not isinstance(value, str) or not value.strip() or len(value) > size:
                raise ValueError('Invalid world rule preset label')
        if 'builtinMode' in row:
            mode = row['builtinMode']
            if not isinstance(mode, str) or mode not in ('purify', 'corruption', 'crimson', 'hallow') or mode in modes:
                raise ValueError('Invalid or duplicate world rule preset mode')
            modes.add(mode)
        rules = row['rules']
        if not isinstance(rules, list) or not 1 <= len(rules) <= 128 or len(encode(row)) > 256 * 1024:
            raise ValueError('World rule preset exceeds rule budget')
        for rule in rules:
            if (not isinstance(rule, dict) or not {'where', 'patch'} <= set(rule) or
                    not set(rule) <= {'where', 'patch', 'limit'} or
                    not integer(rule.get('limit', 0), 0, 2147483647)):
                raise ValueError('Invalid world rule preset rule')
            for side in ('where', 'patch'):
                values = rule[side]
                if not isinstance(values, dict) or (side == 'patch' and not values):
                    raise ValueError('Invalid world rule preset condition or patch')
                for field, value in values.items():
                    if field in (patch_only if side == 'where' else where_only):
                        raise ValueError('World rule preset field on unsupported side')
                    if field == 'material':
                        material(value)
                    elif field in boolean_fields:
                        if type(value) is not bool and not integer(value, 0, 1):
                            raise ValueError('Invalid world rule preset boolean')
                    elif field not in bounds or not integer(value, *bounds[field]):
                        raise ValueError('Unknown or out-of-range world rule preset field')
                if 'platform_style' in values:
                    if ('type' in values and values['type'] != 19) or ('frame_y' in values and
                            (side == 'patch' or values['frame_y'] != values['platform_style'] * 18)):
                        raise ValueError('Conflicting world rule preset platform fields')
                if 'material' in values and any(key in values for key in ('frame_x', 'frame_y', 'platform_style')):
                    raise ValueError('Conflicting world rule preset material fields')
            source = rule['where'].get('material')
            target_material = rule['patch'].get('material')
            if source and 'type' not in rule['where']:
                raise ValueError('World rule preset material match requires tile type')
            if target_material and (not source or source['width'] != target_material['width'] or
                                    source['height'] != target_material['height']):
                raise ValueError('World rule preset material target requires matching dimensions')
            if source and (source['width'] != 1 or source['height'] != 1):
                target = 19 if 'platform_style' in rule['patch'] else rule['patch'].get('type')
                if rule.get('limit', 0) != 0 or (target is not None and target != rule['where'].get('type')):
                    raise ValueError('Unsafe multi-tile world rule preset')
    return rows, {'schema': 1, 'gameVersion': game_version,
                  'inputSha256': sha(data), 'sourceFiles': sources}


def build(root, destination, include_icons=True, conversion_profiles=None, entity_markers=None,
          world_rule_presets=None):
    root = root.resolve(strict=True)
    descriptor_bytes = local_read(root, 'infrastructure/assets/builtin-descriptor.json', 8 * 1024 * 1024)
    descriptor = json.loads(descriptor_bytes)
    if descriptor.get('schema') != 1 or not descriptor.get('gameVersion'):
        raise ValueError('Unsupported viewer resource descriptor')
    source_hashes = {}

    def read_object(ref, default_package='builtin-resources'):
        package = ref.get('package', default_package)
        if package not in ('builtin-resources', 'builtin-items', 'builtin-npcs', 'builtin-rgb'):
            raise ValueError('Unsupported resource package')
        path = ref.get('path', '')
        if not re.fullmatch(r'objects/[a-f0-9]{2}/[a-f0-9]{64}\.(json\.gz|png)', path):
            raise ValueError('Unsupported object path')
        data = local_read(root, f'features/{package}/pages/resources/{PurePosixPath(path).name}')
        if len(data) != ref['bytes'] or sha(data) != ref['sha256']:
            raise ValueError(f'Source integrity failure: {path}')
        source_hashes[path] = ref['sha256']
        if ref.get('encoding') == 'gzip':
            return json.loads(decode_gzip(data, ref['decodedBytes']))
        return data

    families = {}
    extra_provenance = {}
    if conversion_profiles is not None:
        profiles, digest = read_conversion_profiles(conversion_profiles, descriptor['gameVersion'])
        families['player-conversion-profiles'] = profiles
        source_hashes['local-conversion-profiles.json'] = digest
    if entity_markers is not None:
        rows, digest, source_sha = read_entity_markers(entity_markers, descriptor['gameVersion'])
        families['entity-markers'] = rows
        source_hashes['local-entity-markers.json'] = digest
        source_hashes['entity-markers-source'] = source_sha
    if world_rule_presets is not None:
        rows, provenance = read_world_rule_presets(world_rule_presets, descriptor['gameVersion'], root)
        families['world-rule-presets'] = rows
        extra_provenance['worldRulePresets'] = provenance
        source_hashes['local-world-rule-presets.json'] = provenance['inputSha256']
        source_hashes.update(provenance['sourceFiles'])
    for family, shards in descriptor['families'].items():
        if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', family):
            raise ValueError('Invalid family name')
        if family in families:
            raise ValueError('Duplicate supplemental catalog family')
        rows = []
        for shard in shards:
            part = read_object(shard['object'])
            if not isinstance(part, list):
                raise ValueError(f'Not a row catalog: {family}')
            rows.extend(part)
        if len(rows) > 50000:
            raise ValueError('Catalog exceeds row limit')
        families[family] = rows
    index = {str(row['id']): row for row in families.pop('item-index', [])}
    families['items'] = [{**index.get(str(row['id']), {}), **row} for row in families.get('items', [])]
    families['research'] = [dict(row, required=row['research']) for row in index.values() if row.get('research', 0) > 0]

    # Parse only a JSON literal; never evaluate a source program.
    achievement_path = 'features/achievements/pages/services/catalog.mjs'
    achievement_source = local_read(root, achievement_path).decode('utf-8')
    match = re.search(r'export\s+const\s+ACHIEVEMENT_CATALOG\s*=\s*', achievement_source)
    if not match:
        raise ValueError('Achievement catalog JSON literal not found')
    achievements, _ = json.JSONDecoder().raw_decode(achievement_source[match.end():])
    families['achievements'] = [dict(value, id=key) for key, value in achievements.items()]
    source_hashes[achievement_path] = sha(achievement_source.encode('utf-8'))

    payloads = {}
    textures = read_object(descriptor['textures']) if include_icons else {}
    for family, ref in descriptor.get('imageCatalogs', {}).items() if include_icons else []:
        for key, value in read_object(ref).items():
            if isinstance(value, list):
                width, height, digest, size = value
                textures[key] = {'width': width, 'height': height, 'object': {
                    'path': f'objects/{digest[:2]}/{digest}.png', 'sha256': digest,
                    'bytes': size, 'package': ref.get('package', f'builtin-{family}')}}
            else:
                textures[key] = value

    def add_png(data):
        if len(data) < 33 or len(data) > 8 * 1024 * 1024 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
            raise ValueError('Invalid PNG header')
        width, height = struct.unpack('>II', data[16:24])
        if not 0 < width <= 8192 or not 0 < height <= 8192 or width * height > 4194304:
            raise ValueError('PNG exceeds safe decoding limits')
        path = f'images/{sha(data)}.png'
        payloads[path] = data
        return path

    for family, rows in families.items():
        seen = set()
        for row in rows:
            key = str(row['id'])
            if key in seen:
                raise ValueError(f'Duplicate {family} ID {key}')
            seen.add(key)
            if not include_icons:
                continue
            asset = row.get('texture') or row.get('assetId')
            if family == 'buffs':
                asset = f'Buff_{key}'
            if family == 'tiles':
                asset = f"Tiles_{row['type']}"
            if family == 'walls':
                asset = f"Wall_{row['type']}"
            if family == 'paints':
                asset = f"Item_{row.get('itemId')}"
            if asset in textures:
                row['icon'] = add_png(read_object(textures[asset]['object']))
            elif family == 'achievements':
                position = row.get('iconIndex')
                if not isinstance(position, int) or not 0 <= position <= 10000:
                    raise ValueError('Invalid achievement icon index')
                row['icon'] = add_png(local_read(root, f'features/achievements/pages/static/icons/{position}.png'))
    # Explicit world atlases are separate from inventory/catalog icon previews.
    # Source programs are never evaluated: parse only their JSON data literal.
    flags_path = 'features/fusion/vendor/circuit/actuation-data.mjs'
    flags_source = local_read(root, flags_path).decode('utf-8')
    marker = 'export default Object.freeze('
    if marker not in flags_source:
        raise ValueError('Native material flags literal missing')
    flags, _ = json.JSONDecoder().raw_decode(flags_source.split(marker, 1)[1])
    source_hashes[flags_path] = sha(flags_source.encode('utf-8'))
    recipe_path = 'features/fusion/render/vendor/exploreTV/overview-frame-recipes.mjs'
    recipe_source = local_read(root, recipe_path).decode('utf-8')
    recipe_match = re.search(r'export const ORDINARY_BLOCKS = Object.freeze\(\[([\s\S]*?)\]\)', recipe_source)
    if not recipe_match:
        raise ValueError('Ordinary frame metadata missing')
    ordinary_literal = re.sub(r'//[^\n]*', '', recipe_match[1])
    if not re.fullmatch(r'[\d,\s]+', ordinary_literal):
        raise ValueError('Invalid ordinary frame metadata')
    ordinary = {int(n) for n in re.findall(r'\d+', ordinary_literal)}
    important = set(flags['tileFrameImportant'])
    source_hashes[recipe_path] = sha(recipe_source.encode('utf-8'))
    fusion_path = 'features/fusion/assets/packaged-textures.mjs'
    fusion_source = local_read(root, fusion_path).decode('utf-8')
    fusion, _ = json.JSONDecoder().raw_decode(fusion_source.split('export default ', 1)[1])
    if fusion['gameVersion'] != descriptor['gameVersion'] or fusion['schema'] != 1:
        raise ValueError('Fusion texture version mismatch')
    source_hashes[fusion_path] = sha(fusion_source.encode('utf-8'))
    for family, prefix in [('tile-atlases', 'Tiles_'), ('wall-atlases', 'Wall_')]:
        atlas_rows = []
        if include_icons:
            for name, texture in fusion['textures'].items():
                if not re.fullmatch(re.escape(prefix) + r'\d+\.png', name):
                    continue
                package, digest, size = texture
                if package not in (1, 2, 3, 4) or not re.fullmatch(r'[a-f0-9]{64}', digest):
                    raise ValueError('Invalid fusion texture reference')
                path = f'features/fusion-textures-{package}/static/{digest}.png'
                data = local_read(root, path, 8 * 1024 * 1024)
                if len(data) != size or sha(data) != digest:
                    raise ValueError('Fusion texture integrity mismatch')
                source_hashes[path] = digest
                type_id = int(name[len(prefix):-4])
                width, height = struct.unpack('>II', data[16:24])
                atlas_rows.append({'id': type_id, 'icon': add_png(data),
                    'width': width, 'height': height,
                    'frameImportant': type_id in important if family == 'tile-atlases' else False,
                    'ordinaryFrames': type_id in ordinary if family == 'tile-atlases' else False})
        families[family] = atlas_rows
    stable = read_object(descriptor['rgb']['stableCandidates'])
    if not isinstance(stable, list) or len(stable) > 50000:
        raise ValueError('Invalid stable RGB candidates')
    for row in stable:
        if not isinstance(row, list) or len(row) != 8 or any(type(v) is not int or v < 0 for v in row) or row[0] not in (0, 1) or row[7] != 1:
            raise ValueError('Invalid stable RGB candidate')
    families['stable-rgb'] = [{'id': i, 'kind': r[0], 'type': r[1], 'variant': r[2],
        'paint': r[3], 'rgb': r[4:7], 'stable': r[7]} for i, r in enumerate(stable)]
    for family, rows in families.items():
        payloads[f'catalog/{family}.json'] = encode(rows)
    if sum(len(v) for k, v in payloads.items() if k.startswith('catalog/')) > MAX_META:
        raise ValueError('Catalog exceeds metadata budget')
    if len(payloads) > 30000 or sum(map(len, payloads.values())) > MAX_PACK:
        raise ValueError('Resource pack exceeds budget')
    entries, offset = [], 0
    for path, data in sorted(payloads.items()):
        entries.append({'path': path, 'offset': offset, 'bytes': len(data), 'sha256': sha(data)})
        offset += len(data)
    manifest = {'format': 1, 'gameVersion': descriptor['gameVersion'], 'provenance': {
        'source': 'user-supplied-local-viewer', 'descriptorSha256': sha(descriptor_bytes),
        'sourceReleaseSha256': descriptor.get('releaseSha256'),
        'sourceManifestSha256': descriptor.get('provenance', {}).get('sourceManifestSha256'),
        'sourceObjects': source_hashes,
        'redistributionRights': 'not-granted-by-this-tool', **extra_provenance}, 'entries': entries}
    header = encode(manifest)
    if len(header) > 8 * 1024 * 1024 or 12 + len(header) + offset > MAX_PACK:
        raise ValueError('Resource pack exceeds total budget')
    # Exclusive creation protects both source resources and existing user files.
    with destination.open('xb') as output:
        output.write(b'ABCPACK1' + struct.pack('<I', len(header)) + header)
        for path in sorted(payloads):
            output.write(payloads[path])
    return {'gameVersion': descriptor['gameVersion'], 'families': {k: len(v) for k, v in families.items()},
            'icons': sum(k.startswith('images/') for k in payloads), 'bytes': destination.stat().st_size,
            'sha256': sha(destination.read_bytes())}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('viewer_root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--metadata-only', action='store_true')
    parser.add_argument('--conversion-profiles', type=Path,
                        help='Private, source-pinned gameplay conversion metadata JSON')
    parser.add_argument('--entity-markers', type=Path,
                        help='Private, source-pinned entity selector metadata JSON')
    parser.add_argument('--world-rule-presets', type=Path,
                        help='Private literal world rules JSON with matching source-file hashes')
    args = parser.parse_args()
    print(json.dumps(build(args.viewer_root, args.output, not args.metadata_only,
                           args.conversion_profiles, args.entity_markers, args.world_rule_presets), indent=2))
