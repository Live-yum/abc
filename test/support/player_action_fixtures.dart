import 'package:terraforge/domain/resource_catalog.dart';

ResourceCatalog playerActionCatalog({
  int maxStack = 99,
  List<int> eligible = const [1, 2, 3, 90],
}) => ResourceCatalog(
  gameVersion: '1.4.5.8',
  provenance: {},
  families: {
    'items': [
      CatalogEntry('items', {
        'id': 10,
        'maxStack': maxStack,
        'gameplay': {'damage': 20},
        'eligiblePrefixes': eligible,
      }),
    ],
    'prefixes': [
      for (final id in [1, 2, 3, 90])
        CatalogEntry('prefixes', {
          'id': id,
          'name': 'Prefix $id',
          'stats': {
            'dmg': id == 1
                ? 1.1
                : id == 90
                ? 1.3
                : 1.2,
          },
          'pools': <String>[],
        }),
    ],
  },
);
Map<String, Object?> slot(
  int id, {
  int count = 1,
  int prefix = 0,
  bool favorite = false,
}) => {
  'itemType': id,
  'stack': id == 0 ? 0 : count,
  'prefix': prefix,
  'favorited': favorite,
};
