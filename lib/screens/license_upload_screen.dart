import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_edge_detection/flutter_edge_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/app_theme.dart';
import '../services/document_verification.dart';
import '../services/document_template_matcher.dart';
import 'verification_screen.dart';

class LicenseUploadScreen extends StatefulWidget {
  const LicenseUploadScreen({super.key});

  @override
  State<LicenseUploadScreen> createState() => _LicenseUploadScreenState();
}

class _LicenseUploadScreenState extends State<LicenseUploadScreen> {
  File? _pickedImage;
  bool _isLoading = false;
  String? _errorText;

  Future<void> _scanDocument() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final imagePath = p.join(
        directory.path,
        'license_scan_${DateTime.now().millisecondsSinceEpoch}.jpeg',
      );

      final success = await FlutterEdgeDetection.detectEdge(
        imagePath,
        canUseGallery: true,
        androidScanTitle: "Scan Driver's License",
        androidCropTitle: 'Adjust Edges',
        androidCropBlackWhiteTitle: 'Black & White',
        androidCropReset: 'Reset',
      );

      if (success) {
        setState(() {
          _pickedImage = File(imagePath);
          _errorText = null;
        });
      }
    } on EdgeDetectionException catch (e) {
      setState(() => _errorText = 'Scan failed: ${e.message}');
    } catch (e) {
      setState(() => _errorText = 'Could not open scanner.');
    }
  }

  Future<void> _handleSubmit() async {
    if (_pickedImage == null) {
      setState(() => _errorText = 'Please scan your license first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      debugPrint('LICENSE: Signed-in UID = $uid');

      if (uid == null) {
        throw Exception('No signed-in user found.');
      }

      // ------------------------------------------------------------
      // LAYER 1: Document template matching
      // ------------------------------------------------------------

      final imageBytes = await _pickedImage!.readAsBytes();

      final templateResult = await DocumentTemplateMatcher.matchDocument(
        imageBytes: imageBytes,
        allowedTemplates: const [
          DocumentTemplate.malaysiaLicense,
          DocumentTemplate.philippinesLicense,
        ],
      );

      debugPrint('========== LICENSE LAYER 1 ==========');
      debugPrint('Document Type: ${templateResult.documentType}');
      debugPrint('Good Matches: ${templateResult.goodMatches}');
      debugPrint('Is Match: ${templateResult.isMatch}');
      debugPrint('======================================');

      // Reject the document if it does not visually match
      // either supported driving license template.
      if (!templateResult.isMatch) {
        setState(() {
          _isLoading = false;
          _errorText = 'The document does not appear to be a valid Malaysian or Philippine driving license.';
        });
        return;
      }

      final detectedDocumentType = templateResult.documentType;

      final detectedDocumentName = DocumentTemplateMatcher.getDocumentName(
        detectedDocumentType,
      );

      // ------------------------------------------------------------
      // Upload document to Firebase Storage
      // ------------------------------------------------------------

      final ref = FirebaseStorage.instance
          .ref()
          .child('users')
          .child(uid)
          .child('driving_license.jpg');

      await ref.putFile(
        _pickedImage!,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      debugPrint('LICENSE STEP 1: Storage upload successful');

      final downloadUrl = await ref.getDownloadURL();

      debugPrint('LICENSE STEP 2: Download URL obtained');

      // ------------------------------------------------------------
      // LAYER 2: OCR verification
      // ------------------------------------------------------------

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final registeredName = (userDoc.data()?['name'] ?? '') as String;

      final result = await DocumentVerificationService.analyze(
        imageFile: _pickedImage!,
        registeredFullName: registeredName,
        checkExpiry: true,
      );

      // ------------------------------------------------------------
      // Save verification results
      // ------------------------------------------------------------

      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

      debugPrint('LICENSE STEP 3: About to save Firestore fields for $uid');

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final latestDoc = await transaction.get(userRef);

        final attempts =
            (latestDoc.data()?['documentSubmissionAttempts'] as num?)
                ?.toInt() ??
            0;

        if (attempts >= 3) {
          throw Exception('Document resubmission limit reached.');
        }

        transaction.update(userRef, {
          'licenseUrl': downloadUrl,

          // Layer 1
          'licenseDocumentType': detectedDocumentName,
          'licenseTemplateMatches': templateResult.goodMatches,
          'licenseTemplateMatched': templateResult.isMatch,

          // Layer 2
          'licenseOcrText': result.extractedText,
          'licenseNameMatches': result.nameMatches,
          'licenseExpired': result.isExpired,
          'licenseExpiryDetected': result.expiryDateFound?.toIso8601String(),
          'licenseIdNumber': result.idNumberFound,

          // Submission
          'documentSubmissionAttempts': FieldValue.increment(1),
          'verificationStatus': 'pending',
        });
      });

      debugPrint('LICENSE STEP 4: Firestore update successful');

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const VerificationScreen()),
      );
    } catch (e, stackTrace) {
      debugPrint('========== LICENSE UPLOAD ERROR ==========');
      debugPrint('ERROR: $e');
      debugPrint('STACK TRACE: $stackTrace');
      debugPrint('==========================================');

      setState(() {
        _isLoading = false;
        _errorText = 'Upload failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.offWhite,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: AppColors.primaryTeal,
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_back_ios,
                          size: 14,
                          color: Colors.white,
                        ),
                        SizedBox(width: 4),
                        Text('Back', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Upload Driver's License",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const SizedBox(height: 10),

                  if (_errorText != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        _errorText!,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  Container(
                    height: 220,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.gray),
                    ),
                    child: _pickedImage != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              _pickedImage!,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                            ),
                          )
                        : const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.document_scanner_outlined,
                                  size: 48,
                                  color: AppColors.primaryTeal,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'No document scanned yet',
                                  style: TextStyle(
                                    color: Colors.black45,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _scanDocument,
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: Text(
                        _pickedImage == null ? 'Scan Document' : 'Rescan',
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppColors.gray),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleSubmit,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Submit'),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
