import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class DocumentImageProcessor {
  static Uint8List normalize(Uint8List originalBytes) {
    debugPrint('[ImageProcessor] Starting normalization');

    final decoded = img.decodeImage(originalBytes);

    if (decoded == null) {
      throw Exception(
        'Could not read the image. Please scan your document again.',
      );
    }

    debugPrint(
      '[ImageProcessor] Decoded dimensions: '
      '${decoded.width} x ${decoded.height}',
    );

    final oriented = img.bakeOrientation(decoded);

    debugPrint(
      '[ImageProcessor] After EXIF orientation: '
      '${oriented.width} x ${oriented.height}',
    );

    const maxWidth = 1600;
    const maxHeight = 1200;

    final scale = math.min(
      1.0,
      math.min(maxWidth / oriented.width, maxHeight / oriented.height),
    );

    final width = (oriented.width * scale).round();
    final height = (oriented.height * scale).round();

    final resized = width == oriented.width && height == oriented.height
        ? oriented
        : img.copyResize(oriented, width: width, height: height);

    debugPrint(
      '[ImageProcessor] Final dimensions: '
      '${resized.width} x ${resized.height}',
    );

    final output = Uint8List.fromList(img.encodeJpg(resized, quality: 90));

    debugPrint('[ImageProcessor] JPEG encoding completed');

    return output;
  }
}
