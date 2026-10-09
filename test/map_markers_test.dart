import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/map_markers.dart';

void main() {
  test('same tile variants remain independent through style, persistence and removal', () {
    final first = MapMarkerSelector(locate: 1, frameX: 0, frameY: 0);
    final second = MapMarkerSelector(
      locate: 1,
      frameX: 18,
      frameY: 0,
      frameXMod: 36,
    );
    final profile = MapMarkerProfile()
        .toggle('tile', 42)
        .toggle('tile', 42, selector: first)
        .toggle('tile', 42, selector: second)
        .style(
          'tile',
          42,
          selector: second,
          color: '#ABCDEF',
          radius: 4,
          lineWidth: 2,
        );
    expect(profile.length, 3);
    expect(profile.markers.map((m) => m.key).toSet(), hasLength(3));
    expect(profile.markers.first.key, 'tile:42');
    expect(profile.markers[1].color, '#FF3B30');
    expect(profile.markers[2].color, '#ABCDEF');
    expect(
      MapMarkerProfile.decode(profile.encode()).encode(),
      profile.encode(),
    );
    final withoutFirst = profile.remove('tile', 42, selector: first);
    expect(withoutFirst.length, 2);
    expect(withoutFirst.contains('tile', 42, selector: second), isTrue);
    expect(withoutFirst.contains('tile', 42), isTrue);
    expect(profile.remove('tile', 42).length, 2);
    expect(profile.toggle('tile', 42, selector: second).length, 2);
    final request = profile.toEngineRequest()['tile_markers'] as List;
    expect(request[2], {
      'tile_type': 42,
      'locate': 1,
      'frame_x': 18,
      'frame_y': 0,
      'frame_x_mod': 36,
      'color': '#ABCDEF',
      'radius': 4,
      'line_width': 2,
    });
    expect((request[0] as Map).containsKey('locate'), isFalse);
  });
  test('selector validates native bounds and canonical duplicates', () {
    for (final raw in [
      null,
      {'unknown': 0},
      {'locate': 1.0},
      {'locate': true},
      {'locate': -1},
      {'locate': 3},
      {'locate': 1, 'frame_x': -2},
      {'locate': 1, 'frame_y': 32768},
      {'locate': 1, 'frame_x_mod': -1},
      {'locate': 1, 'frame_y_mod': 32768},
      {'frame_x': 0},
    ]) {
      expect(() => MapMarkerSelector.fromJson(raw), throwsFormatException);
    }
    expect(
      () => MapMarker(kind: 'item', id: 42, selector: MapMarkerSelector()),
      throwsFormatException,
    );
    final broad = MapMarker(kind: 'tile', id: 42);
    expect(
      MapMarker(kind: 'tile', id: 42, selector: MapMarkerSelector()).key,
      broad.key,
    );
    expect(
      () => MapMarkerProfile([
        broad,
        MapMarker(kind: 'tile', id: 42, selector: MapMarkerSelector()),
      ]),
      throwsFormatException,
    );
    final anyFrame = MapMarker(
      kind: 'tile',
      id: 42,
      selector: MapMarkerSelector(locate: 1),
    );
    final ignoredModulo = MapMarker(
      kind: 'tile',
      id: 42,
      selector: MapMarkerSelector(locate: 1, frameXMod: 36),
    );
    expect(anyFrame.key, ignoredModulo.key);
    expect(
      () => MapMarkerProfile([anyFrame, ignoredModulo]),
      throwsFormatException,
    );
    expect(
      () => MapMarkerProfile([
        MapMarker(
          kind: 'tile',
          id: 42,
          selector: MapMarkerSelector(locate: 2, frameX: 0),
        ),
        MapMarker(
          kind: 'tile',
          id: 42,
          selector: MapMarkerSelector(locate: 2, frameX: 18),
        ),
      ]),
      throwsFormatException,
    );
    final bound = MapMarkerSelector(
      locate: 2,
      frameX: 32767,
      frameY: 32767,
      frameXMod: 32767,
      frameYMod: 32767,
    );
    expect(MapMarkerSelector.fromJson(bound.toJson()).key, bound.key);
  });
  test('version one profiles without selectors retain their legacy shape', () {
    final raw = {
      'version': 1,
      'markers': [
        {
          'kind': 'tile',
          'id': 42,
          'color': '#123456',
          'radius': 3,
          'lineWidth': 1,
        },
      ],
    };
    final profile = MapMarkerProfile.fromJson(raw);
    expect(profile.toJson(), raw);
    expect(profile.markers.single.selector, isNull);
    for (final selector in [
      null,
      {'locate': '1'},
      {'locate': 1, 'extra': 3},
    ]) {
      expect(
        () => MapMarker.fromJson({
          ...profile.markers.single.toJson(),
          'selector': selector,
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'toggle deduplicates, removal and clear preserve prior immutable profile',
    () {
      final empty = MapMarkerProfile();
      final first = empty.toggle('item', 10);
      expect(empty.isEmpty, isTrue);
      expect(first.toggle('item', 10).isEmpty, isTrue);
      expect(first.toggle('tile', 10).length, 2);
      expect(first.clear().isEmpty, isTrue);
      expect(first.length, 1);
      expect(() => first.markers.clear(), throwsUnsupportedError);
      expect(
        () => MapMarkerProfile([first.markers.single, first.markers.single]),
        throwsFormatException,
      );
    },
  );
  test(
    'selector-heavy profiles cannot persist beyond the existing byte budget',
    () {
      expect(
        () => MapMarkerProfile(
          List.generate(
            256,
            (id) => MapMarker(
              kind: 'tile',
              id: id,
              selector: MapMarkerSelector(
                locate: 1,
                frameX: 32767,
                frameY: 32767,
                frameXMod: 32767,
                frameYMod: 32767,
              ),
            ),
          ),
        ),
        throwsFormatException,
      );
    },
  );
  test('combined bound and malformed actions are atomic', () {
    final full = MapMarkerProfile(
      List.generate(
        256,
        (i) => MapMarker(kind: i.isEven ? 'item' : 'tile', id: i + 1),
      ),
    );
    expect(() => full.toggle('item', 999), throwsFormatException);
    expect(full.length, 256);
    expect(full.toggle('item', 1).length, 255);
    for (final kind in ['invalid', 'item', 'tile']) {
      expect(() => full.toggle(kind, -1), throwsFormatException);
    }
    expect(() => full.toggle('item', 0), throwsFormatException);
    expect(MapMarkerProfile().toggle('tile', 0).length, 1);
    expect(() => full.toggle('tile', 65536), throwsFormatException);
    expect(() => full.toggle('item', 2147483648), throwsFormatException);
    for (final color in ['red', '#ABC', '#123456FF', '#GG0000']) {
      expect(
        () => full.style('item', 1, color: color, radius: 30, lineWidth: 3),
        throwsFormatException,
      );
    }
    expect(
      () => full.style('item', 1, color: '#000000', radius: 0, lineWidth: 3),
      throwsFormatException,
    );
    expect(
      () => full.style('item', 1, color: '#000000', radius: 61, lineWidth: 3),
      throwsFormatException,
    );
    expect(
      () => full.style('item', 1, color: '#000000', radius: 1, lineWidth: 16),
      throwsFormatException,
    );
    expect(
      () => full.style('item', 999, color: '#000000', radius: 1, lineWidth: 1),
      throwsFormatException,
    );
    expect(full.markers.first.radius, 30);
  });
  test('versioned deterministic roundtrip preserves unknown numeric IDs', () {
    final profile = MapMarkerProfile()
        .toggle('item', 2147483647)
        .toggle('tile', 65535)
        .style('tile', 65535, color: '#abcdef', radius: 60, lineWidth: 15);
    expect(
      MapMarkerProfile.decode(profile.encode()).encode(),
      profile.encode(),
    );
    expect(profile.markers.last.color, '#ABCDEF');
    final output = profile.toJson();
    ((output['markers'] as List)[0] as Map)['id'] = 3;
    expect(profile.markers.first.id, 2147483647);
    expect(profile.length, 2);
    for (final value in [
      null,
      {},
      {'version': 2, 'markers': []},
      {'version': 1, 'markers': [], 'extra': true},
      {
        'version': 1,
        'markers': [
          {
            'kind': 'tile',
            'id': 1.0,
            'color': '#123456',
            'radius': 3,
            'lineWidth': 1,
          },
        ],
      },
      {
        'version': 1,
        'markers': [
          {...profile.markers.first.toJson(), 'extra': true},
        ],
      },
    ]) {
      expect(() => MapMarkerProfile.fromJson(value), throwsFormatException);
    }
    expect(() => MapMarkerProfile.decode(' ' * 32769), throwsFormatException);
    expect(
      () => MapMarkerProfile.decode(
        jsonEncode({
          'version': 1,
          'markers': List.filled(257, profile.markers.first.toJson()),
        }),
      ),
      throwsFormatException,
    );
  });
  test(
    'engine request uses exact protocol field names and no fabricated assets',
    () {
      final profile = MapMarkerProfile()
          .toggle('item', 1)
          .toggle('tile', 21)
          .style('tile', 21, color: '#123456', radius: 1, lineWidth: 15);
      expect(profile.toEngineRequest(maxWidth: 960), {
        'max_w': 960,
        'chest_markers': [
          {'item_id': 1, 'color': '#FF3B30', 'radius': 30, 'line_width': 3},
        ],
        'tile_markers': [
          {'tile_type': 21, 'color': '#123456', 'radius': 1, 'line_width': 15},
        ],
      });
      expect(() => MapMarkerProfile().toEngineRequest(), throwsFormatException);
      expect(() => profile.toEngineRequest(maxWidth: 0), throwsFormatException);
    },
  );
}
