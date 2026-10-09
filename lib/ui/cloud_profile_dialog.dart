import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Edits a local draft. The caller owns persistence and session freshness checks.
Future<Map<String, dynamic>?> showCloudProfileDialog(
  BuildContext context, {
  required Map<String, dynamic> account,
  required String? Function(String) normalizeAvatar,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (context) => _CloudProfileDialog(
    account: Map<String, dynamic>.of(account),
    normalizeAvatar: normalizeAvatar,
  ),
);

class _CloudProfileDialog extends StatefulWidget {
  const _CloudProfileDialog({
    required this.account,
    required this.normalizeAvatar,
  });

  final Map<String, dynamic> account;
  final String? Function(String) normalizeAvatar;

  @override
  State<_CloudProfileDialog> createState() => _CloudProfileDialogState();
}

class _CloudProfileDialogState extends State<_CloudProfileDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _nickname;
  late final TextEditingController _avatar;
  late final String? _originalAvatar;
  String? _normalizedAvatar;

  @override
  void initState() {
    super.initState();
    _nickname = TextEditingController(
      text: widget.account['nickname']?.toString() ?? '',
    );
    _avatar = TextEditingController(
      text: widget.account['avatar']?.toString() ?? '',
    );
    _originalAvatar = _normalizeAvatar(_avatar.text, widget.normalizeAvatar);
  }

  @override
  void dispose() {
    _nickname.dispose();
    _avatar.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop(<String, dynamic>{
      'id': widget.account['id'],
      'nickname': _nickname.text.trim(),
      'avatar': _normalizedAvatar!,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑云端账户'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CloudAccountAvatar(
              avatarUrl: _originalAvatar,
              nickname: widget.account['nickname']?.toString() ?? '',
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('cloudProfileNickname'),
              controller: _nickname,
              maxLength: 80,
              maxLengthEnforcement: MaxLengthEnforcement.none,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '昵称'),
              validator: (value) {
                final nickname = value?.trim() ?? '';
                if (nickname.isEmpty) return '请输入昵称';
                if (nickname.length > 80) return '昵称不能超过 80 个字符';
                return null;
              },
            ),
            TextFormField(
              key: const ValueKey('cloudProfileAvatar'),
              controller: _avatar,
              maxLength: 2048,
              maxLengthEnforcement: MaxLengthEnforcement.none,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '头像地址',
                helperText: '使用 HTTPS 地址或服务内资源路径；留空可恢复默认头像。',
                helperMaxLines: 3,
                errorMaxLines: 3,
              ),
              validator: (value) {
                _normalizedAvatar = _normalizeAvatar(
                  value ?? '',
                  widget.normalizeAvatar,
                );
                return _normalizedAvatar == null
                    ? '头像地址无效：请使用有效的 HTTPS 地址或服务内路径，且不超过 2048 个字符'
                    : null;
              },
            ),
            TextButton.icon(
              key: const ValueKey('cloudProfileClearAvatar'),
              onPressed: () => _avatar.clear(),
              icon: const Icon(Icons.person_outline),
              label: const Text('恢复默认头像'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存到云端')),
    ],
  );
}

/// Displays a fallback until the user explicitly chooses to load the image.
/// No authentication headers are attached to a third-party avatar request.
class CloudAccountAvatar extends StatefulWidget {
  const CloudAccountAvatar({
    super.key,
    required this.avatarUrl,
    required this.nickname,
  });

  final String? avatarUrl;
  final String nickname;

  @override
  State<CloudAccountAvatar> createState() => _CloudAccountAvatarState();
}

class _CloudAccountAvatarState extends State<CloudAccountAvatar> {
  String? _requestedUrl;

  @override
  void didUpdateWidget(CloudAccountAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarUrl != widget.avatarUrl) _requestedUrl = null;
  }

  Widget _fallback(BuildContext context) {
    final nickname = widget.nickname.trim();
    return CircleAvatar(
      radius: 24,
      child: nickname.isEmpty
          ? const Icon(Icons.person_outline)
          : Text(nickname.characters.first.toUpperCase()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _httpsAvatar(widget.avatarUrl ?? '');
    final canLoad = url != null && url != _requestedUrl;
    return Tooltip(
      message: canLoad ? '加载头像' : '账户头像',
      child: Semantics(
        label: canLoad ? '加载头像' : '账户头像',
        button: canLoad,
        child: SizedBox.square(
          dimension: 48,
          child: ClipOval(
            child: Material(
              child: InkWell(
                key: const ValueKey('cloudAvatarLoad'),
                onTap: canLoad
                    ? () => setState(() => _requestedUrl = url)
                    : null,
                child: url != null && url == _requestedUrl
                    ? Image.network(
                        url,
                        key: ValueKey(url),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => _fallback(context),
                        loadingBuilder: (_, child, progress) =>
                            progress == null ? child : _fallback(context),
                      )
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          _fallback(context),
                          if (canLoad)
                            const Positioned(
                              right: 0,
                              bottom: 0,
                              child: Icon(Icons.download, size: 16),
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _avatarControls = RegExp(r'[\x00-\x1f\x7f-\x9f]');
final _encodedAvatarControls = RegExp(
  r'%(?:0[0-9a-f]|1[0-9a-f]|7f)',
  caseSensitive: false,
);

bool _unsafeAvatarText(String value) =>
    value.length > 2048 ||
    _avatarControls.hasMatch(value) ||
    _encodedAvatarControls.hasMatch(value) ||
    value.contains(r'\') ||
    RegExp(r'^https://[^/?#]*@', caseSensitive: false).hasMatch(value.trim());

String? _httpsAvatar(String value) {
  if (_unsafeAvatarText(value)) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.authority.contains('@') ||
      uri.hasFragment) {
    return null;
  }
  return uri.toString();
}

String? _normalizeAvatar(String value, String? Function(String) normalize) {
  if (_unsafeAvatarText(value)) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.authority.contains('@') ||
      (uri.hasScheme && _httpsAvatar(trimmed) == null) ||
      (!uri.hasScheme && uri.hasAuthority)) {
    return null;
  }
  try {
    final normalized = normalize(trimmed);
    return normalized == null ? null : _httpsAvatar(normalized);
  } catch (_) {
    return null;
  }
}
