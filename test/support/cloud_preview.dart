import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Repository-authored thumbnail fixture, never a user's image.
Uint8List syntheticCloudPreview() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
