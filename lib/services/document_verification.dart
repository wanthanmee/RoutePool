import 'dart:io';

import 'package:flutter/material.dart';

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

      final today = DateUtils.dateOnly(DateTime.now());

      if (expiryDate != null) {
        isExpired = DateUtils.dateOnly(expiryDate).isBefore(today);
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

  /// Extracts text from a vehicle registration document using ML Kit OCR.
  static Future<String> extractText({required File imageFile}) async {
    final inputImage = InputImage.fromFile(imageFile);

    final RecognizedText recognizedText = await _recognizer.processImage(
      inputImage,
    );

    final extractedText = recognizedText.text;

    debugPrint('========== VEHICLE REGISTRATION OCR ==========');
    debugPrint('Extracted text:\n$extractedText');
    debugPrint('==============================================');

    return extractedText;
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

  /// Finds the latest valid date recognized in the OCR text.
  /// Supports numeric dates and dates such as 31 DIS 2024.
  static DateTime? _findLatestDate(String text) {
    final numericPattern = RegExp(r'\b(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})\b');

    final textMonthPattern = RegExp(
      r'\b(\d{1,2})\s+'
      r'(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|DIS|DIC)'
      r'\s+(\d{4})\b',
      caseSensitive: false,
    );

    const months = <String, int>{
      'JAN': 1,
      'FEB': 2,
      'MAR': 3,
      'APR': 4,
      'MAY': 5,
      'JUN': 6,
      'JUL': 7,
      'AUG': 8,
      'SEP': 9,
      'OCT': 10,
      'NOV': 11,
      'DEC': 12,
      'DIS': 12,
      'DIC': 12,
    };

    final dates = <DateTime>[];

    void addDate(int day, int month, int year) {
      if (year < 100) {
        year += 2000;
      }

      if (year < 2000 ||
          year > 2100 ||
          month < 1 ||
          month > 12 ||
          day < 1 ||
          day > 31) {
        return;
      }

      final date = DateTime(year, month, day);

      // Reject invalid dates such as 31 February.
      if (date.year == year && date.month == month && date.day == day) {
        dates.add(date);
      }
    }

    // Extract numeric dates, such as 31/12/2024.
    for (final match in numericPattern.allMatches(text)) {
      addDate(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      );
    }

    // Extract dates with month names, such as 31 DIS 2024.
    for (final match in textMonthPattern.allMatches(text)) {
      final month = months[match.group(2)!.toUpperCase()];

      if (month != null) {
        addDate(int.parse(match.group(1)!), month, int.parse(match.group(3)!));
      }
    }

    if (dates.isEmpty) {
      return null;
    }

    dates.sort((a, b) => a.compareTo(b));
    return dates.last;
  }

  /// Function: dispose
  /// --------------------------------------------------------------
  /// Disposes of the text recognizer to free up resources.
  /// Should be called when the service is no longer needed.
  static void dispose() {
    _recognizer.close();
  }
}
