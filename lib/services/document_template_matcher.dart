import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv.dart' as cv;

/// Represents the document types supported by RoutePool Layer 1.
enum DocumentTemplate {
  myKad,
  philippinePassport,
  malaysiaLicense,
  philippinesLicense,
  unknown,
}

/// Represents the result returned by Layer 1 template matching.
class DocumentTemplateMatchResult {
  final DocumentTemplate documentType;
  final int goodMatches;
  final bool isMatch;

  DocumentTemplateMatchResult({
    required this.documentType,
    required this.goodMatches,
    required this.isMatch,
  });
}

/// Performs non-ML visual template matching for RoutePool documents.
///
/// Layer 1 checks whether the uploaded image visually resembles
/// one of the supported document templates using ORB feature matching.
///
/// Layer 2 remains responsible for OCR and identity-related checks.
class DocumentTemplateMatcher {
  /// Minimum number of good ORB matches required.
  static const int minimumGoodMatches = 20;

  /// Minimum percentage of uploaded ORB features that must
  /// produce a good match.
  static const double minimumMatchRatio = 0.01;

  /// Lowe ratio used to determine whether a feature match
  /// is sufficiently distinctive.
  static const double loweRatio = 0.75;

  /// Matches an uploaded document against the permitted templates.
  static Future<DocumentTemplateMatchResult> matchDocument({
    required Uint8List imageBytes,
    required List<DocumentTemplate> allowedTemplates,
  }) async {
    if (allowedTemplates.isEmpty) {
      throw ArgumentError('No document templates were provided.');
    }

    // Decode uploaded image.
    final uploadedImage = cv.imdecode(imageBytes, cv.IMREAD_GRAYSCALE);

    if (uploadedImage.isEmpty) {
      throw Exception('Unable to decode the uploaded document image.');
    }

    // Create ORB feature detector.
    final orb = cv.ORB.create(nFeatures: 2000, scaleFactor: 1.2, nLevels: 8);

    // Detect features in uploaded image.
    final uploadedResult = orb.detectAndCompute(uploadedImage, cv.Mat.empty());

    final uploadedDescriptors = uploadedResult.$2;

    if (uploadedDescriptors.isEmpty) {
      uploadedImage.dispose();
      orb.dispose();

      return DocumentTemplateMatchResult(
        documentType: DocumentTemplate.unknown,
        goodMatches: 0,
        isMatch: false,
      );
    }

    DocumentTemplate bestTemplate = DocumentTemplate.unknown;
    int bestMatchCount = 0;
    double bestMatchRatio = 0.0;

    for (final template in allowedTemplates) {
      final assetPath = getTemplateAssetPath(template);

      final ByteData templateData = await rootBundle.load(assetPath);

      final templateBytes = templateData.buffer.asUint8List(
        templateData.offsetInBytes,
        templateData.lengthInBytes,
      );

      final templateImage = cv.imdecode(templateBytes, cv.IMREAD_GRAYSCALE);

      if (templateImage.isEmpty) {
        continue;
      }

      // Detect features in template.
      final templateResult = orb.detectAndCompute(
        templateImage,
        cv.Mat.empty(),
      );

      final templateDescriptors = templateResult.$2;

      if (templateDescriptors.isEmpty) {
        templateImage.dispose();
        continue;
      }

      // Match ORB descriptors using Hamming distance.
      final matcher = cv.BFMatcher.create(
        type: cv.NORM_HAMMING,
        crossCheck: false,
      );

      final matches = matcher.knnMatch(
        uploadedDescriptors,
        templateDescriptors,
        2,
      );

      int goodMatches = 0;

      // Lowe ratio test.
      for (final pair in matches) {
        if (pair.length < 2) {
          continue;
        }

        final best = pair[0];
        final secondBest = pair[1];

        if (best.distance < loweRatio * secondBest.distance) {
          goodMatches++;
        }
      }

      // Calculate the percentage of uploaded features that matched.
      final int uploadedFeatureCount = uploadedDescriptors.rows;

      final double matchRatio = uploadedFeatureCount > 0
          ? goodMatches / uploadedFeatureCount
          : 0.0;

      debugPrint('Template: ${getDocumentName(template)}');
      debugPrint('Good Matches: $goodMatches');
      debugPrint('Uploaded Features: ${uploadedDescriptors.rows}');
      debugPrint('Match Ratio: ${(matchRatio * 100).toStringAsFixed(2)}%');

      // A template must satisfy BOTH conditions.
      final passesMatchCount = goodMatches >= minimumGoodMatches;

      final passesMatchRatio = matchRatio >= minimumMatchRatio;

      final passesTemplate = passesMatchCount && passesMatchRatio;

      debugPrint('Passes Match Count: $passesMatchCount');
      debugPrint('Passes Match Ratio: $passesMatchRatio');
      debugPrint('Template Accepted: $passesTemplate');
      debugPrint('--------------------------------------');

      if (passesTemplate &&
          (bestTemplate == DocumentTemplate.unknown ||
              matchRatio > bestMatchRatio ||
              (matchRatio == bestMatchRatio && goodMatches > bestMatchCount))) {
        bestMatchCount = goodMatches;
        bestMatchRatio = matchRatio;
        bestTemplate = template;
      }

      matcher.dispose();
      templateImage.dispose();
    }

    uploadedImage.dispose();
    orb.dispose();

    final isMatch =
        bestTemplate != DocumentTemplate.unknown &&
        bestMatchCount >= minimumGoodMatches &&
        bestMatchRatio >= minimumMatchRatio;

    debugPrint('========== FINAL TEMPLATE RESULT ==========');
    debugPrint('Best Template: ${getDocumentName(bestTemplate)}');
    debugPrint('Good Matches: $bestMatchCount');
    debugPrint('Match Ratio: ${(bestMatchRatio * 100).toStringAsFixed(2)}%');
    debugPrint('Is Match: $isMatch');
    debugPrint('===========================================');

    return DocumentTemplateMatchResult(
      documentType: isMatch ? bestTemplate : DocumentTemplate.unknown,
      goodMatches: bestMatchCount,
      isMatch: isMatch,
    );
  }

  /// Returns the asset path for each supported document template.
  static String getTemplateAssetPath(DocumentTemplate template) {
    switch (template) {
      case DocumentTemplate.myKad:
        return 'assets/document_templates/mykad_template.jpg';

      case DocumentTemplate.philippinePassport:
        return 'assets/document_templates/philippine_passport_template.jpg';

      case DocumentTemplate.malaysiaLicense:
        return 'assets/document_templates/malaysia_license_template.jpg';

      case DocumentTemplate.philippinesLicense:
        return 'assets/document_templates/philippine_license_template.jpg';

      case DocumentTemplate.unknown:
        throw ArgumentError('Unknown document has no template asset.');
    }
  }

  /// Returns a user-friendly document name.
  static String getDocumentName(DocumentTemplate template) {
    switch (template) {
      case DocumentTemplate.myKad:
        return 'MyKad';

      case DocumentTemplate.philippinePassport:
        return 'Philippine Passport';

      case DocumentTemplate.malaysiaLicense:
        return 'Malaysian Driving License';

      case DocumentTemplate.philippinesLicense:
        return 'Philippine Driving License';

      case DocumentTemplate.unknown:
        return 'Unknown Document';
    }
  }
}
