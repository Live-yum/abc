import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:terraforge/platform/files.dart';

void main() {
  test(
    'iOS custom-file picker supplies UTIs and validates extension',
    () async {
      List<XTypeGroup>? captured;
      final gateway = PlatformFiles(
        platform: TargetPlatform.iOS,
        picker: (groups) async {
          captured = groups;
          return XFile.fromData(
            Uint8List.fromList([1]),
            path: 'a.wld',
            name: 'a.wld',
          );
        },
      );
      expect((await gateway.pick('world'))!.name, 'a.wld');
      expect(captured!.single.uniformTypeIdentifiers, ['public.data']);
      final bad = PlatformFiles(
        picker: (_) async =>
            XFile.fromData(Uint8List(1), path: 'bad.exe', name: 'bad.exe'),
      );
      expect(() => bad.pick('world'), throwsFormatException);
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '$platform uses named share export and handles cancellation',
      () async {
        ShareParams? captured;
        final gateway = PlatformFiles(
          platform: platform,
          share: (params) async {
            captured = params;
            return const ShareResult('', ShareResultStatus.dismissed);
          },
        );
        expect(await gateway.save('a.wld', Uint8List.fromList([1, 2])), false);
        expect(captured!.fileNameOverrides, ['a.wld']);
        expect(captured!.files!.length, 1);
        expect(captured!.sharePositionOrigin!.isEmpty, false);
        expect(await captured!.files!.single.readAsBytes(), [1, 2]);
      },
    );
  }
}
