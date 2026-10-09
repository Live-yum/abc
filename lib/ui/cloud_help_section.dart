import 'package:flutter/material.dart';

import '../cloud/cloud_models.dart';

/// The embedding panel owns requests. Building this section never loads help.
class CloudHelpSection extends StatelessWidget {
  const CloudHelpSection({
    super.key,
    required this.articles,
    required this.loading,
    required this.loaded,
    this.error,
    required this.onLoad,
  });

  final List<CloudHelpArticle> articles;
  final bool loading;
  final bool loaded;
  final String? error;
  final VoidCallback? onLoad;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('帮助信息', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('cloudHelpLoad'),
            onPressed: loading ? null : onLoad,
            icon: const Icon(Icons.help_outline),
            label: Text(error != null ? '重试加载帮助' : (loaded ? '刷新帮助' : '加载帮助')),
          ),
          if (loading) ...[
            const LinearProgressIndicator(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('正在加载帮助信息…'),
            ),
          ],
          if (error != null)
            Text(
              _plainText(error!, 500),
              key: const ValueKey('cloudHelpError'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!loading && error == null && !loaded) const Text('点击加载帮助查看云端说明。'),
          if (!loading && error == null && loaded && articles.isEmpty)
            const Text('暂无帮助信息'),
          for (var index = 0; index < articles.length; index++)
            ExpansionTile(
              key: PageStorageKey(
                'cloudHelpArticle:$index:${articles[index].id}',
              ),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              expandedAlignment: Alignment.centerLeft,
              title: Text(
                _plainText(articles[index].title, 200),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              children: [Text(_plainText(articles[index].content, 20000))],
            ),
        ],
      ),
    ),
  );
}

// Help may contain HTML from the service. Only inert, bounded text reaches the
// widget tree: no HTML renderer, URL launcher, image loader or embedded browser.
String _plainText(String source, int limit) {
  var value = source.length > limit ? source.substring(0, limit) : source;
  value = value
      .replaceAll(RegExp(r'<!--[\s\S]*?(?:-->|$)'), '')
      .replaceAll(
        RegExp(
          r'<(script|style|iframe|object|noscript|template)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'<br\b[^>]*>|</(?:p|div|li|h[1-6]|tr)\s*>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAllMapped(
        RegExp(
          r'&(#x[0-9a-f]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);',
          caseSensitive: false,
        ),
        (match) {
          final entity = match[1]!.toLowerCase();
          if (entity.startsWith('#')) {
            final hex = entity.startsWith('#x');
            final code = int.tryParse(
              entity.substring(hex ? 2 : 1),
              radix: hex ? 16 : 10,
            );
            if (code == null ||
                code < 0 ||
                code > 0x10ffff ||
                (code >= 0xd800 && code <= 0xdfff)) {
              return '';
            }
            return String.fromCharCode(code);
          }
          return const {
            'amp': '&',
            'lt': '<',
            'gt': '>',
            'quot': '"',
            'apos': "'",
            'nbsp': ' ',
          }[entity]!;
        },
      )
      .replaceAll(
        RegExp(
          r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
        ),
        '',
      )
      .replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n')
      .trim();
  return value;
}
