import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../screens/passenger_home.dart' show RPColors;

enum _PhotoAction { gallery, camera, remove }

/// Shows a "choose photo" sheet, then uploads / removes the photo.
///
/// Returns:
///  - the new download URL after a successful upload,
///  - '' after a successful removal,
///  - null if the user cancelled or something failed (a snackbar is shown
///    for failures).
///
/// Storage:   profile_pics/{uid}.jpg
/// Firestore: users/{uid}.profilePic
Future<String?> changeProfilePhoto(
  BuildContext context, {
  required bool hasPhoto,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  final action = await showModalBottomSheet<_PhotoAction>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          const Text(
            'Profile photo',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: RPColors.textDark,
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(
              Icons.photo_library_outlined,
              color: RPColors.teal,
            ),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.of(ctx).pop(_PhotoAction.gallery),
          ),
          ListTile(
            leading: const Icon(
              Icons.photo_camera_outlined,
              color: RPColors.teal,
            ),
            title: const Text('Take a photo'),
            onTap: () => Navigator.of(ctx).pop(_PhotoAction.camera),
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                'Remove photo',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.of(ctx).pop(_PhotoAction.remove),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (action == null) return null;

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('You are not signed in.')),
    );
    return null;
  }

  final ref = FirebaseStorage.instance.ref('profile_pics/$uid.jpg');
  final userDoc = FirebaseFirestore.instance.collection('users').doc(uid);

  try {
    if (action == _PhotoAction.remove) {
      await userDoc.set({'profilePic': ''}, SetOptions(merge: true));
      try {
        await ref.delete();
      } catch (_) {
        // The file may not exist; the Firestore field is what matters.
      }
      return '';
    }

    final picked = await ImagePicker().pickImage(
      source: action == _PhotoAction.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 80,
    );
    if (picked == null) return null;

    await ref.putFile(
      File(picked.path),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    final url = await ref.getDownloadURL();

    // The file path never changes, so add a version to the URL to stop
    // the app showing the previous (cached) photo.
    final versionedUrl = '$url&v=${DateTime.now().millisecondsSinceEpoch}';

    await userDoc.set({'profilePic': versionedUrl}, SetOptions(merge: true));
    return versionedUrl;
  } catch (e) {
    debugPrint('Profile photo error: $e');
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Could not update your photo. Please try again.'),
      ),
    );
    return null;
  }
}
