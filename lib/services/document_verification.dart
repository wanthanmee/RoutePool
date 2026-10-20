import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Class: DocumentVerificationResult
/// --------------------------------------------------------------
/// Represents the result of analyzing a document image, including extracted text,
/// name match status, expiration status, and any found ID number or expiry date.
class DocumentVerificationResult {
  final String extractedText;
  final bool nameMatches;
  final bool isExpired;
  final DateTime? expiryDateFound;
  final String? idNumberFound;

  /// Constructor for DocumentVerificationResult.
  DocumentVerificationResult({
    required this.extractedText,
    required this.nameMatches,
    required this.isExpired,
    required this.expiryDateFound,
    required this.idNumberFound,
  });
}

/// Class: DocumentVerificationService
/// --------------------------------------------------------------
/// Provides functionality to analyze document images for text extraction, name matching,
/// ID number detection, and expiration date checking using ML Kit's text recognition.
class DocumentVerificationService {
  static final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  /// Function: analyze
  /// --------------------------------------------------------------
  /// Analyzes the provided image file for text, checks if the extracted text matches
  /// the registered full name,optionally checks for expiration date, and looks for an ID number.
  static Future<DocumentVerificationResult> analyze({
    required File imageFile,
    required String registeredFullName,
    bool checkExpiry = false,
  }) async {
    final inputImage = InputImage.fromFile(imageFile);
    final RecognizedText recognizedText = await _recognizer.processImage(
      inputImage,
    );

    final extractedText = recognizedText.text;

    final nameMatches = _checkNameMatch(extractedText, registeredFullName);
    final idNumber = _findIdNumber(extractedText);

    // Check for expiration date if requested
    DateTime? expiryDate;
    bool isExpired = false;
    if (checkExpiry) {
      expiryDate = _findLatestDate(extractedText);
      if (expiryDate != null) {
        isExpired = expiryDate.isBefore(DateTime.now());
      }
    }
    // Return the result encapsulated in a DocumentVerificationResult object
    return DocumentVerificationResult(
      extractedText: extractedText,
      nameMatches: nameMatches,
      isExpired: isExpired,
      expiryDateFound: expiryDate,
      idNumberFound: idNumber,
    );
  }

  /// Function: _checkNameMatch
  /// --------------------------------------------------------------
  /// Checks if the extracted text contains at least half of the tokens from the registered full name.
  /// This is a simple heuristic to account for OCR inaccuracies and variations in name representation.
  static bool _checkNameMatch(String ocrText, String registeredName) {
    final normalizedOcr = _normalize(ocrText);
    final nameTokens = _normalize(registeredName)
        .split(' ')
        .where((t) => t.length > 1)
        .toList();

    if (nameTokens.isEmpty) return false;

    final matchedCount = nameTokens
        .where((token) => normalizedOcr.contains(token))
        .length;

    return matchedCount >= (nameTokens.length / 2).ceil();
  }

  /// Function: _normalize
  /// --------------------------------------------------------------
  /// Normalizes the input string by converting it to uppercase, removing
  /// non-alphanumeric characters, and collapsing multiple spaces into one.
  static String _normalize(String input) {
    return input
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Function: _findIdNumber
  /// --------------------------------------------------------------
  /// Looks for a Malaysian NRIC/MyKad number (format: 123456-12-1234) or,
  /// as a fallback, a generic passport-style alphanumeric ID (e.g. A1234567).
  static String? _findIdNumber(String text) {
    final nricPattern = RegExp(r'\b\d{6}-?\d{2}-?\d{4}\b');
    final nricMatch = nricPattern.firstMatch(text);
    if (nricMatch != null) return nricMatch.group(0);

    // Passport numbers commonly look like: one letter, several digits,
    // optionally ending in another letter (e.g. P70474412A). This is more
    // permissive than before to catch that letter-digits-letter shape.
    final passportPattern = RegExp(r'\b[A-Z]\d{6,9}[A-Z]?\b');
    final passportMatches = passportPattern.allMatches(text.toUpperCase());

    for (final match in passportMatches) {
      final candidate = match.group(0)!;
      // Skip short false positives that are really just OCR noise
      if (candidate.length >= 7) {
        return candidate;
      }
    }

    return null;
  }

  /// Function: _findLatestDate
  /// --------------------------------------------------------------
  /// Looks for the latest date in the text, assuming dates are in formats
  /// like DD/MM/YYYY, DD-MM-YYYY, or DD.MM.YYYY.
  static DateTime? _findLatestDate(String text) {
    final pattern = RegExp(r'(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{2,4})');
    final matches = pattern.allMatches(text);

    // Find the latest valid date from the matches
    DateTime? latest;
    for (final match in matches) {
      try {
        final day = int.parse(match.group(1)!);
        final month = int.parse(match.group(2)!);
        var year = int.parse(match.group(3)!);
        if (year < 100) year += 2000;

        final date = DateTime(year, month, day);
        if (date.year < 2000 || date.year > 2100) continue;

        if (latest == null || date.isAfter(latest)) {
          latest = date;
        }
      } catch (_) {
        continue;
      }
    }
    return latest;
  }

  /// Function: dispose
  /// --------------------------------------------------------------
  /// Disposes of the text recognizer to free up resources.
  /// Should be called when the service is no longer needed.
  static void dispose() {
    _recognizer.close();
  }
}
