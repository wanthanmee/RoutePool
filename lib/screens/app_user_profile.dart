// Shared shape for a signed-in user's Firestore data, used by
// PassengerHomeScreen, DriverDashboardScreen, and ProfileScreen so each
// account shows its own real name/phone/role instead of hardcoded mock
// values. Fetched once at login (see login_screen.dart) and passed down.

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

  final String uid;
  final String name;
  final String email;
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