/// Typed view of a signed-in user's Firestore profile.
///
/// The profile is loaded during login and passed to screens that need
/// account-specific identity, role, verification, and photo information.
class AppUserProfile {
  const AppUserProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.phoneNo,
    required this.role,
    required this.verificationStatus,
    this.profilePic = '',
  });

  /// Firestore user document ID and Firebase Authentication UID.
  final String uid;

  /// Display name stored in the user's profile.
  final String name;

  /// Email address associated with the account.
  final String email;

  /// Phone number associated with the account.
  final String phoneNo;

  /// 'passenger' or 'driver', lowercased.
  final String role;

  /// 'pending' | 'approved' | 'rejected'
  final String verificationStatus;

  /// URL of the profile photo. Empty string means no photo uploaded.
  final String profilePic;

  bool get isDriver => role == 'driver';
  bool get isApproved => verificationStatus == 'approved';

  /// Null when there is no photo, so avatars fall back to the person icon.
  String? get avatarUrl => profilePic.trim().isEmpty ? null : profilePic.trim();

  /// Derived badge labels for ProfileScreen. Your current schema only
  /// tracks one verificationStatus per account (not separate IC vs.
  /// license flags), so an approved driver gets both badges and an
  /// approved passenger gets just IC. Adjust here if you later split
  /// verification into separate per-document fields.
  List<String> get verificationBadges {
    if (!isApproved) return [];
    return isDriver
        ? const ['IC Verified', 'License Verified']
        : const ['IC Verified'];
  }

  /// Creates a profile from the fields stored in a Firestore user document.
  ///
  /// Missing or malformed optional profile values are replaced with the
  /// defaults used by the app.
  factory AppUserProfile.fromFirestore(String uid, Map<String, dynamic> data) {
    return AppUserProfile(
      uid: uid,
      name: (data['name'] as String?)?.trim().isNotEmpty == true
          ? data['name'] as String
          : 'User',
      email: (data['email'] as String?) ?? '',
      phoneNo: (data['phoneNo'] as String?) ?? '',
      role: ((data['role'] as String?) ?? 'passenger').toLowerCase(),
      verificationStatus: (data['verificationStatus'] as String?) ?? 'pending',
      profilePic: (data['profilePic'] as String?) ?? '',
    );
  }
}