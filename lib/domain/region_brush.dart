import 'resource_catalog.dart';

enum RegionBrushKind {
  block,
  wall,
  paint,
  liquid,
  wire,
  shape,
  actuator,
  erase,
}

enum RegionBrushLayer { block, wall, liquid, wire, all }

/// An immutable continuous-layer tool. Only the documented intent keys are
/// accepted; coordinates, arbitrary cell patches and object frames are not tools.
/// The host owns stroke history and authoritative world-candidate validation.
class RegionBrush {
  static final _objectTypes = Expando<Set<int>>();
  final RegionBrushKind kind;
  final RegionBrushLayer layer;
  final int id, paint, liquidType, amount, mask, shape;
  final bool remove;

  const RegionBrush._(
    this.kind, {
    this.layer = RegionBrushLayer.block,
    this.id = 0,
    this.paint = 0,
    this.liquidType = 1,
    this.amount = 255,
    this.mask = 1,
    this.shape = 0,
    this.remove = false,
  });

  factory RegionBrush.block(int id) =>
      RegionBrush.fromIntent({'kind': 'block', 'id': id});
  factory RegionBrush.wall(int id) =>
      RegionBrush.fromIntent({'kind': 'wall', 'id': id});

  @override
  bool operator ==(Object other) =>
      other is RegionBrush &&
      kind == other.kind &&
      layer == other.layer &&
      id == other.id &&
      paint == other.paint &&
      liquidType == other.liquidType &&
      amount == other.amount &&
      mask == other.mask &&
      shape == other.shape &&
      remove == other.remove;

  @override
  int get hashCode => Object.hash(
    kind,
    layer,
    id,
    paint,
    liquidType,
    amount,
    mask,
    shape,
    remove,
  );

  factory RegionBrush.fromIntent(Map<String, Object?> intent) {
    final name = intent['kind'];
    final matches = RegionBrushKind.values.where((kind) => kind.name == name);
    if (matches.isEmpty) throw const FormatException('未知连续画笔');
    final kind = matches.single;
    final keys = switch (kind) {
      RegionBrushKind.block || RegionBrushKind.wall => {'kind', 'id'},
      RegionBrushKind.paint => {'kind', 'layer', 'paint'},
      RegionBrushKind.liquid => {'kind', 'liquidType', 'amount'},
      RegionBrushKind.wire => {'kind', 'mask', 'remove'},
      RegionBrushKind.shape => {'kind', 'shape'},
      RegionBrushKind.actuator => {'kind', 'remove'},
      RegionBrushKind.erase => {'kind', 'layer'},
    };
    if (intent.length != keys.length ||
        intent.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('连续画笔参数缺失或包含未知字段');
    }
    int integer(String key, int min, int max) {
      final value = intent[key];
      if (value is! int || value < min || value > max) {
        throw FormatException('$key 必须为 $min–$max 的整数');
      }
      return value;
    }

    bool removing() {
      final value = intent['remove'];
      if (value is! bool) throw const FormatException('remove 必须为布尔值');
      return value;
    }

    RegionBrushLayer selectedLayer({bool paintOnly = false}) {
      final layers = RegionBrushLayer.values.where(
        (layer) => layer.name == intent['layer'],
      );
      if (layers.isEmpty ||
          (paintOnly &&
              layers.single != RegionBrushLayer.block &&
              layers.single != RegionBrushLayer.wall)) {
        throw const FormatException('当前画笔不支持此图层');
      }
      return layers.single;
    }

    return switch (kind) {
      RegionBrushKind.block ||
      RegionBrushKind.wall => RegionBrush._(kind, id: integer('id', 0, 65535)),
      RegionBrushKind.paint => RegionBrush._(
        kind,
        layer: selectedLayer(paintOnly: true),
        paint: integer('paint', 0, 30),
      ),
      RegionBrushKind.liquid => RegionBrush._(
        kind,
        liquidType: integer('liquidType', 1, 4),
        amount: integer('amount', 0, 255),
      ),
      RegionBrushKind.wire => RegionBrush._(
        kind,
        mask: integer('mask', 1, 15),
        remove: removing(),
      ),
      RegionBrushKind.shape => RegionBrush._(
        kind,
        shape: integer('shape', 0, 5),
      ),
      RegionBrushKind.actuator => RegionBrush._(kind, remove: removing()),
      RegionBrushKind.erase => RegionBrush._(kind, layer: selectedLayer()),
    };
  }

  Map<String, Object?> get intent => Map.unmodifiable({
    'kind': kind.name,
    ...switch (kind) {
      RegionBrushKind.block || RegionBrushKind.wall => {'id': id},
      RegionBrushKind.paint => {'layer': layer.name, 'paint': paint},
      RegionBrushKind.liquid => {'liquidType': liquidType, 'amount': amount},
      RegionBrushKind.wire => {'mask': mask, 'remove': remove},
      RegionBrushKind.shape => {'shape': shape},
      RegionBrushKind.actuator => {'remove': remove},
      RegionBrushKind.erase => {'layer': layer.name},
    },
  });

  /// Null intentionally skips sparse holes, unchanged cells, paint on a missing
  /// layer and shape on air. Structural edits reject unknown/framed foreground
  /// before returning ANY patch, including an all-layer erase. Ordinary status
  /// comes only from the imported source metadata, never an ID guess or frame 0.
  /// A zero liquid amount always clears both amount and type.
  Map<String, int>? patchFor(
    Map<String, int>? cell, {
    ResourceCatalog? catalog,
  }) {
    if (cell == null) return null;
    int value(String key, int max) {
      final value = cell[key];
      if (value == null || value < 0 || value > max) {
        throw FormatException('当前格子的 $key 无效');
      }
      return value;
    }

    final active = value('active', 1) == 1;
    void ordinary(int block) {
      final metadata = catalog?.byId('tile-atlases', block)?.fields;
      if (catalog == null || metadata?['frameImportant'] != false) {
        throw FormatException('方块 $block 缺少已验证的普通方块元数据；家具主体不能连续拆改');
      }
      // Catalogs are deeply immutable. Index once, not once per dragged cell.
      final objects = _objectTypes[catalog] ??= {
        for (final row
            in catalog.families['tile-object-data'] ?? <CatalogEntry>[])
          if (row.fields['tile'] is int) row.fields['tile']! as int,
      };
      if (objects.contains(block)) {
        throw FormatException('方块 $block 有物件占格；请使用完整家具工具');
      }
    }

    void currentOrdinary() {
      if (active) ordinary(value('block', 65535));
    }

    final patch = <String, int>{};
    switch (kind) {
      case RegionBrushKind.block:
        ordinary(id);
        currentOrdinary();
        patch.addAll({
          'active': 1,
          'block': id,
          'blockPaint': 0,
          'slope': 0,
          'inactive': 0,
          'invisibleBlock': 0,
          'fullbrightBlock': 0,
        });
      case RegionBrushKind.wall:
        patch.addAll({'wall': id, 'wallPaint': 0});
      case RegionBrushKind.paint:
        if (layer == RegionBrushLayer.block) {
          if (!active) return null;
          patch['blockPaint'] = paint;
        } else {
          if (value('wall', 65535) == 0) return null;
          patch['wallPaint'] = paint;
        }
      case RegionBrushKind.liquid:
        patch.addAll({
          'liquid': amount,
          'liquidType': amount == 0 ? 0 : liquidType,
        });
      case RegionBrushKind.wire:
        final wires = value('wires', 15);
        patch['wires'] = remove ? wires & ~mask : wires | mask;
      case RegionBrushKind.shape:
        if (!active) return null;
        currentOrdinary();
        patch['slope'] = shape;
      case RegionBrushKind.actuator:
        patch['actuator'] = remove ? 0 : 1;
        if (remove) patch['inactive'] = 0;
      case RegionBrushKind.erase:
        if (layer == RegionBrushLayer.block || layer == RegionBrushLayer.all) {
          currentOrdinary();
          if (active) {
            patch.addAll({
              'active': 0,
              'block': 0,
              'blockPaint': 0,
              'slope': 0,
              'inactive': 0,
              'invisibleBlock': 0,
              'fullbrightBlock': 0,
            });
          }
        }
        if (layer == RegionBrushLayer.wall || layer == RegionBrushLayer.all) {
          patch.addAll({
            'wall': 0,
            'wallPaint': 0,
            'invisibleWall': 0,
            'fullbrightWall': 0,
          });
        }
        if (layer == RegionBrushLayer.liquid || layer == RegionBrushLayer.all) {
          patch.addAll({'liquid': 0, 'liquidType': 0});
        }
        if (layer == RegionBrushLayer.wire || layer == RegionBrushLayer.all) {
          patch.addAll({'wires': 0, 'actuator': 0, 'inactive': 0});
        }
    }
    if (patch.entries.every((entry) => cell[entry.key] == entry.value)) {
      return null;
    }
    return Map.unmodifiable(patch);
  }
}
