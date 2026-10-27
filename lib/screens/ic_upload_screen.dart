import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_edge_detection/flutter_edge_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image/image.dart' as img;

import '../theme/app_theme.dart';
import '../services/document_verification.dart';
import '../services/document_template_matcher.dart';
import '../services/document_image_processor.dart';

import 'license_upload_screen.dart';
import 'verification_screen.dart';

/// Widget: ICUploadScreen
/// -------------------------------------------------------------------
/// Allows users to scan or upload a photo of their MyKad or passport.
class IcUploadScreen extends StatefulWidget {
  /// User role, either `passenger` or `driver`.
  final String role; // 'passenger' or 'driver'

  /// Creates the identity-document upload step for [role].
  const IcUploadScreen({super.key, required this.role});

  @override
  State<IcUploadScreen> createState() => _IcUploadScreenState();
}

/// Scans, validates, and uploads the user's identity document.
class _IcUploadScreenState extends State<IcUploadScreen> {
  File? _pickedImage;
  bool _isLoading = false;
  String? _errorText;

  /// Opens the document scanner and stores the resulting image for review.
  Future<void> _scanDocument() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final imagePath = p.join(
        directory.path,
        'ic_scan_${DateTime.now().millisecondsSinceEpoch}.jpeg',
      );

      final success = await FlutterEdgeDetection.detectEdge(
        imagePath,
        canUseGallery: true,
        androidScanTitle: 'Scan IC / Passport',
        androidCropTitle: 'Adjust Edges',
        androidCropBlackWhiteTitle: 'Black & White',
        androidCropReset: 'Reset',
      );

      if (success) {
        final scannedFile = File(imagePath);

        debugPrint('[ICUpload] Scanned path: $imagePath');
        debugPrint('[ICUpload] File exists: ${await scannedFile.exists()}');

        if (await scannedFile.exists()) {
          final bytes = await scannedFile.readAsBytes();

          debugPrint('[ICUpload] Scanned file size: ${bytes.length} bytes');
          debugPrint('[ICUpload] Starting image decode');

          try {
            final decoded = img.decodeImage(bytes);

            if (decoded == null) {
              debugPrint('[ICUpload] Image decoder returned null');
            } else {
              debugPrint(
                '[ICUpload] Scanned dimensions: '
                '${decoded.width} x ${decoded.height}',
              );
            }
          } catch (e, stackTrace) {
            debugPrint('[ICUpload] Image decoding failed: $e');
            debugPrintStack(stackTrace: stackTrace);
          }
        }

        setState(() {
          _pickedImage = scannedFile;
          _errorText = null;
        });
      }
    } on EdgeDetectionException catch (e) {
      setState(() => _errorText = 'Scan failed: ${e.message}');
    } catch (e) {
      setState(() => _errorText = 'Could not open scanner.');
    }
  }

  /// Validates the selected document and submits it for account verification.
  Future<void> _handleSubmit() async {
    if (_pickedImage == null) {
      setState(() => _errorText = 'Please scan your IC/Passport first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('No signed-in user found.');

      // --------------------------------------------------------------
      // Layer 1: Document Template Verification
      // --------------------------------------------------------------
      // The passenger/driver may submit either:
      // - Malaysian MyKad
      // - Philippine Passport
      //
      // Layer 1 checks whether the submitted image visually matches
      // one of the supported document templates before continuing.
      // --------------------------------------------------------------

      final originalFile = _pickedImage!;

      debugPrint('[ICUpload] Submit started');
      debugPrint('[ICUpload] Original path: ${originalFile.path}');

      final originalBytes = await originalFile.readAsBytes();
      debugPrint('[ICUpload] Original bytes: ${originalBytes.length}');

      final normalizedBytes = DocumentImageProcessor.normalize(originalBytes);

      final normalizedImage = img.decodeImage(normalizedBytes);
      if (normalizedImage != null) {
        debugPrint(
          '[ICUpload] Normalized dimensions: '
          '${normalizedImage.width} x ${normalizedImage.height}',
        );
      }

      debugPrint('[ICUpload] Normalization completed');

      // Write a normalized JPEG file so the existing OCR and
      // Firebase Storage code can continue accepting a File.
      final tempDirectory = await getTemporaryDirectory();

      final normalizedFile = File(
        p.join(
          tempDirectory.path,
          'normalized_ic_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ),
      );

      await normalizedFile.writeAsBytes(normalizedBytes, flush: true);

      // Use the normalized file for the rest of the submission flow.
      _pickedImage = normalizedFile;

      // Refresh the preview to show the normalized image.
      if (mounted) {
        setState(() {});
      }

      // Delete the original scanner output if it is a different file.
      if (originalFile.path != normalizedFile.path) {
        try {
          await originalFile.delete();
        } catch (e) {
          debugPrint('Could not remove temporary original image: $e');
        }
      }

      // Run template matching on the normalized JPEG.
      final templateResult = await DocumentTemplateMatcher.matchDocument(
        imageBytes: normalizedBytes,
        allowedTemplates: [
          DocumentTemplate.myKad,
          DocumentTemplate.philippinePassport,
        ],
      );

      if (!templateResult.isMatch) {
        throw Exception(
          'The submitted document could not be identified as a '
          'supported MyKad or Philippine Passport.',
        );
      }

      // --------------------------------------------------------------
      // Upload the document only after Layer 1 succeeds.
      // --------------------------------------------------------------

      final ref = FirebaseStorage.instance
          .ref()
          .child('users')
          .child(uid)
          .child('ic_passport.jpg');

      // DEBUG: Check the upload details
      debugPrint('[Storage] UID: $uid');
      debugPrint('[Storage] Full path: ${ref.fullPath}');
      debugPrint('[Storage] File exists: ${await _pickedImage!.exists()}');
      debugPrint('[Storage] File size: ${await _pickedImage!.length()} bytes');

      // Upload the document
      await ref.putFile(
        _pickedImage!,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      final downloadUrl = await ref.getDownloadURL();

      // --------------------------------------------------------------
      // Layer 2: OCR Verification
      // --------------------------------------------------------------
      // Pull the registered name so we can compare it against
      // the name printed on the scanned document.
      // --------------------------------------------------------------

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final registeredName = (userDoc.data()?['name'] ?? '') as String;

      final result = await DocumentVerificationService.analyze(
        imageFile: _pickedImage!,
        registeredFullName: registeredName,
        checkExpiry: false,
      );

      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
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
          'icPassport': downloadUrl,
          'icOcrText': result.extractedText,
          'icNameMatches': result.nameMatches,
          'icIdNumber': result.idNumberFound,
          if (widget.role != 'driver') ...{
            'documentSubmissionAttempts': FieldValue.increment(1),
            'verificationStatus': 'pending',
          },
        });
      });

      if (!mounted) return;

      if (widget.role == 'driver') {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LicenseUploadScreen()),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const VerificationScreen()),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('IC/PASSPORT SUBMISSION FAILED: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _errorText = 'Upload failed: $e';
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
                  'Upload IC/ Passport',
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
                              fit: BoxFit.contain,
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
