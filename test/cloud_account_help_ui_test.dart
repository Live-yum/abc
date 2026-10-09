import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/cloud/cloud_models.dart';
import 'package:terraforge/ui/cloud_help_section.dart';
import 'package:terraforge/ui/cloud_profile_dialog.dart';

class _FailingImageClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const HttpException('Test image unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String? _normalizeAvatar(String value) => value.startsWith('/')
    ? Uri.parse('https://service.example/').resolve(value).toString()
    : value;

Future<void> _openProfile(
  WidgetTester tester, {
  required void Function(Map<String, dynamic>?) onResult,
  Map<String, dynamic> account = const {
    'id': 7,
    'nickname': 'Explorer',
    'avatar': '',
    'openid': 'never-return-this-field',
  },
  String? Function(String) normalizeAvatar = _normalizeAvatar,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(
                await showCloudProfileDialog(
                  context,
                  account: account,
                  normalizeAvatar: normalizeAvatar,
                ),
              );
            },
            child: const Text('Edit account'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit account'));
  await tester.pumpAndSettle();
}

Future<void> _showHelp(
  WidgetTester tester, {
  List<CloudHelpArticle> articles = const [],
  bool loading = false,
  bool loaded = false,
  String? error,
  VoidCallback? onLoad,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CloudHelpSection(
          articles: articles,
          loading: loading,
          loaded: loaded,
          error: error,
          onLoad: onLoad,
        ),
      ),
    ),
  ),
);

void main() {
  var imageRequests = 0;
  void cloudTestWidgets(String description, WidgetTesterCallback callback) {
    testWidgets(description, (tester) async {
      imageRequests = 0;
      debugNetworkImageHttpClientProvider = () {
        imageRequests++;
        return _FailingImageClient();
      };
      try {
        await callback(tester);
      } finally {
        debugNetworkImageHttpClientProvider = null;
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
    });
  }

  cloudTestWidgets(
    'profile cancellation discards edits and can reopen safely',
    (tester) async {
      final results = <Map<String, dynamic>?>[];
      await _openProfile(tester, onResult: results.add);
      await tester.enterText(
        find.byKey(const ValueKey('cloudProfileNickname')),
        'Unsaved',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.tap(find.text('Edit account'));
      await tester.pumpAndSettle();
      expect(find.text('Explorer'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(results, [null, null]);
      expect(imageRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  cloudTestWidgets(
    'profile save returns only id nickname and normalized avatar',
    (tester) async {
      Map<String, dynamic>? saved;
      await _openProfile(tester, onResult: (value) => saved = value);
      await tester.enterText(
        find.byKey(const ValueKey('cloudProfileNickname')),
        '  New explorer  ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('cloudProfileAvatar')),
        '/media/avatar.png',
      );
      await tester.pump();
      expect(imageRequests, 0);
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.text('保存到云端'));
      await tester.pumpAndSettle();
      expect(saved, {
        'id': 7,
        'nickname': 'New explorer',
        'avatar': 'https://service.example/media/avatar.png',
      });
      expect(imageRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  cloudTestWidgets('profile clear avatar returns an explicit empty reset', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await _openProfile(
      tester,
      account: {
        'id': 8,
        'nickname': 'Explorer',
        'avatar': 'https://images.example/old.png',
      },
      onResult: (value) => saved = value,
    );
    expect(imageRequests, 0);
    await tester.tap(find.byKey(const ValueKey('cloudProfileClearAvatar')));
    await tester.tap(find.text('保存到云端'));
    await tester.pumpAndSettle();
    expect(saved, {'id': 8, 'nickname': 'Explorer', 'avatar': ''});
    expect(imageRequests, 0);
  });

  cloudTestWidgets(
    'profile rejects invalid avatars without image requests or save',
    (tester) async {
      var returned = false;
      await _openProfile(tester, onResult: (_) => returned = true);
      final invalid = [
        'http://images.example/avatar.png',
        'javascript:alert(1)',
        'data:image/png;base64,AA==',
        '//images.example/avatar.png',
        'https://user:password@images.example/avatar.png',
        'https://@images.example/avatar.png',
        'https://images.example/avatar.png#fragment',
        'https://images.example/avatar.png#',
        'https://images.example/\nimage.png',
        'https://images.example/%0aimage.png',
        '/media/avatar.png#fragment',
        'https://images.example/${'x' * 2048}',
      ];
      for (final avatar in invalid) {
        // Feed the validator raw values too; a single-line platform editor
        // normally removes pasted newlines before validation.
        tester
                .widget<TextFormField>(
                  find.byKey(const ValueKey('cloudProfileAvatar')),
                )
                .controller!
                .text =
            avatar;
        await tester.pump();
        await tester.ensureVisible(find.text('保存到云端'));
        await tester.tap(find.text('保存到云端'));
        await tester.pumpAndSettle();
        expect(find.textContaining('头像地址无效'), findsOneWidget, reason: avatar);
        expect(returned, false, reason: avatar);
        expect(imageRequests, 0, reason: avatar);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  cloudTestWidgets('normalizer cannot return an unsafe absolute URL', (
    tester,
  ) async {
    var returned = false;
    await _openProfile(
      tester,
      normalizeAvatar: (_) => 'http://service.example/avatar.png',
      onResult: (_) => returned = true,
    );
    await tester.enterText(
      find.byKey(const ValueKey('cloudProfileAvatar')),
      '/avatar.png',
    );
    await tester.tap(find.text('保存到云端'));
    await tester.pumpAndSettle();
    expect(find.textContaining('头像地址无效'), findsOneWidget);
    expect(returned, false);
    expect(imageRequests, 0);
  });

  cloudTestWidgets(
    'profile nickname validation rejects blank and oversized values',
    (tester) async {
      var returned = false;
      await _openProfile(tester, onResult: (_) => returned = true);
      await tester.enterText(
        find.byKey(const ValueKey('cloudProfileNickname')),
        '   ',
      );
      await tester.tap(find.text('保存到云端'));
      await tester.pumpAndSettle();
      expect(find.text('请输入昵称'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('cloudProfileNickname')),
        'N' * 81,
      );
      await tester.tap(find.text('保存到云端'));
      await tester.pumpAndSettle();
      expect(find.text('昵称不能超过 80 个字符'), findsOneWidget);
      expect(returned, false);
      expect(imageRequests, 0);
    },
  );

  cloudTestWidgets('avatar loads only on request and falls back on failure', (
    tester,
  ) async {
    Widget avatar(String url) => MaterialApp(
      home: Scaffold(
        body: CloudAccountAvatar(avatarUrl: url, nickname: 'Explorer'),
      ),
    );
    await tester.pumpWidget(avatar('https://images.example/first.png'));
    expect(find.text('E'), findsOneWidget);
    expect(find.byTooltip('加载头像'), findsOneWidget);
    expect(imageRequests, 0);
    await tester.tap(find.byKey(const ValueKey('cloudAvatarLoad')));
    await tester.pumpAndSettle();
    expect(imageRequests, 1);
    expect(find.text('E'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(avatar('https://images.example/second.png'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.byTooltip('加载头像'), findsOneWidget);
    expect(imageRequests, 1);
    await tester.pumpWidget(avatar('http://images.example/unsafe.png'));
    expect(find.byTooltip('加载头像'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cloudAvatarLoad')));
    await tester.pumpAndSettle();
    expect(imageRequests, 1);
  });

  cloudTestWidgets(
    'help starts idle and loads only through the explicit action',
    (tester) async {
      var loads = 0;
      await _showHelp(tester, onLoad: () => loads++);
      await tester.pump();
      expect(loads, 0);
      expect(find.text('点击加载帮助查看云端说明。'), findsOneWidget);
      await tester.tap(find.text('加载帮助'));
      expect(loads, 1);
      await _showHelp(tester, loading: true, onLoad: () => loads++);
      await tester.pump();
      expect(find.text('正在加载帮助信息…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('cloudHelpLoad')))
            .onPressed,
        isNull,
      );
      expect(loads, 1);
      expect(imageRequests, 0);
    },
  );

  cloudTestWidgets(
    'help errors allow retry and a loaded empty result is explicit',
    (tester) async {
      var loads = 0;
      await _showHelp(tester, error: '帮助暂时不可用，请稍后重试。', onLoad: () => loads++);
      expect(find.text('帮助暂时不可用，请稍后重试。'), findsOneWidget);
      expect(find.text('暂无帮助信息'), findsNothing);
      await tester.tap(find.text('重试加载帮助'));
      expect(loads, 1);
      await _showHelp(tester, loaded: true, onLoad: () => loads++);
      expect(find.text('暂无帮助信息'), findsOneWidget);
      expect(find.text('刷新帮助'), findsOneWidget);
    },
  );

  cloudTestWidgets(
    'help expands sanitized plain text without embedded networking',
    (tester) async {
      await _showHelp(
        tester,
        loaded: true,
        articles: const [
          CloudHelpArticle(
            id: 'start',
            title: '<b>Getting started &amp; safety</b>',
            content:
                '<script>doNotRun()</script><style>doNotShow</style>'
                '<p>Use cloud &amp; local.</p>'
                '<img src="https://untrusted.example/image" onerror="bad()">'
                '<a href="javascript:bad()">Next</a> &lt;safe&gt;.&#10;'
                '<iframe src="https://untrusted.example">hidden</iframe>',
          ),
        ],
      );
      expect(find.text('Getting started & safety'), findsOneWidget);
      expect(find.text('Use cloud & local.\nNext <safe>.'), findsNothing);
      await tester.tap(find.text('Getting started & safety'));
      await tester.pumpAndSettle();
      expect(find.text('Use cloud & local.\nNext <safe>.'), findsOneWidget);
      expect(find.textContaining('doNotRun'), findsNothing);
      expect(find.textContaining('untrusted.example'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(imageRequests, 0);
      await tester.tap(find.text('Getting started & safety'));
      await tester.pumpAndSettle();
      expect(find.text('Use cloud & local.\nNext <safe>.'), findsNothing);
    },
  );

  cloudTestWidgets('help text is bounded and fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _showHelp(
      tester,
      loaded: true,
      articles: [
        CloudHelpArticle(id: 'large', title: 'T' * 500, content: 'C' * 30000),
      ],
    );
    expect(find.text('T' * 200), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.text('C' * 20000), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(imageRequests, 0);
  });

  cloudTestWidgets('profile remains usable in a narrow viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? saved;
    await _openProfile(tester, onResult: (value) => saved = value);
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('cloudProfileNickname')),
      '小屏幕昵称',
    );
    await tester.ensureVisible(find.text('保存到云端'));
    await tester.tap(find.text('保存到云端'));
    await tester.pumpAndSettle();
    expect(saved?['nickname'], '小屏幕昵称');
    expect(tester.takeException(), isNull);
    expect(imageRequests, 0);
  });
}
