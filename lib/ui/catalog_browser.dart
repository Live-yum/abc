import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../domain/resource_catalog.dart';
import '../platform/resource_store.dart';

/// Bounded viewport with lazily built rows and lazy image decoding.
/// Must be placed in a bounded-height parent (Expanded or SizedBox).
class CatalogBrowser extends StatefulWidget {
  final ResourceStore store;
  final String initialFamily;
  final ValueChanged<CatalogEntry>? onSelected;
  const CatalogBrowser({
    super.key,
    required this.store,
    this.initialFamily = 'items',
    this.onSelected,
  });
  @override
  State<CatalogBrowser> createState() => _CatalogBrowserState();
}

class _CatalogBrowserState extends State<CatalogBrowser> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late String _family;
  String? _category;
  List<CatalogEntry> _rows = const [];
  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant CatalogBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.initialFamily != widget.initialFamily) {
      _reset();
    }
  }

  void _reset() {
    final families = widget.store.catalog.families;
    _family = families.containsKey(widget.initialFamily)
        ? widget.initialFamily
        : families.keys.first;
    _category = null;
    _filter();
  }

  void _filter() {
    _rows = widget.store.catalog.search(
      _family,
      query: _query.text,
      category: _category,
    );
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.store.catalog;
    final categories = catalog.categories(_family).toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              value: _family,
              items: [
                for (final entry in catalog.families.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text('${entry.key} (${entry.value.length})'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _family = value;
                    _category = null;
                    _filter();
                  });
                }
              },
            ),
            if (categories.isNotEmpty)
              DropdownButton<String>(
                value: _category ?? '',
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部分类')),
                  for (final category in categories)
                    DropdownMenuItem(value: category, child: Text(category)),
                ],
                onChanged: (value) => setState(() {
                  _category = value;
                  _filter();
                }),
              ),
            Text('版本 ${catalog.gameVersion} · ${_rows.length} 条'),
          ],
        ),
        TextField(
          controller: _query,
          decoration: const InputDecoration(
            labelText: '搜索名称、原始 ID 或英文名',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (_) => setState(_filter),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _rows.isEmpty
              ? const Center(child: Text('没有匹配的目录记录'))
              : ListView.builder(
                  key: ValueKey('catalog-$_family'),
                  controller: _scroll,
                  itemCount: _rows.length,
                  itemExtent: 76,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(152),
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    final icon = widget.store.iconBytes(row);
                    return ListTile(
                      key: ValueKey('${row.family}:${row.id}'),
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: icon == null
                            ? const Icon(Icons.category_outlined)
                            : Image(
                                image: ResizeImage(
                                  MemoryImage(icon),
                                  width: 96,
                                  height: 96,
                                  policy: ResizeImagePolicy.fit,
                                ),
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.none,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.broken_image_outlined),
                              ),
                      ),
                      title: Text(
                        row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'ID ${row.id} · ${row.fields['internalName'] ?? row.category}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => widget.onSelected != null
                          ? widget.onSelected!(row)
                          : _details(context, row),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _details(BuildContext context, CatalogEntry row) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${row.name} · ${row.id}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: SelectableText(
              row.fields.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
