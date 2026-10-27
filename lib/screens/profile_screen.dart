import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_user_profile.dart';
import 'edit_profile_screen.dart';
import 'emergency_contacts_screen.dart';
import 'login_screen.dart';
import 'passenger_home.dart' show RPColors;
import '../services/profile_photo_service.dart';
import 'settings_screen.dart';

/// Displays account details, verification badges, and profile actions.
class ProfileScreen extends StatefulWidget {
  /// Creates the profile page for [userProfile].
  const ProfileScreen({
    super.key,
    required this.userProfile,
    this.verificationBadgesOverride,
    this.avatarImageUrl,
    this.onEditProfile,
    this.onEmergencyContacts,
    this.onSettings,
    this.onChangePhoto,
  });

  /// Profile data for the currently signed-in account.
  final AppUserProfile userProfile;

  /// Override the badges derived from userProfile.verificationBadges if
  /// you need custom labels for a specific case. Leave null to use the
  /// account's real verification status.
  final List<String>? verificationBadgesOverride;

  /// Optional avatar URL that takes precedence over the profile's stored photo.
  final String? avatarImageUrl;

  /// Optional overrides. Leave null to use the built-in pages.
  /// Callbacks for replacing the default profile actions.
  final VoidCallback? onEditProfile;
  final VoidCallback? onEmergencyContacts;
  final VoidCallback? onSettings;
  final VoidCallback? onChangePhoto;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

/// Resolves profile presentation values and handles profile-related actions.
class _ProfileScreenState extends State<ProfileScreen> {
  bool _uploadingPhoto = false;

  List<String> get _badges =>
      widget.verificationBadgesOverride ??
      widget.userProfile.verificationBadges;

  String get _name => widget.userProfile.name;

  String get _phone => widget.userProfile.phoneNo;

  /// Explicit override first, otherwise the photo stored in Firestore.
  String? get _avatarUrl =>
      widget.avatarImageUrl ?? widget.userProfile.avatarUrl;

  // ------------------------------------------------------------
  // NAVIGATION
  // ------------------------------------------------------------

  /// Opens the edit screen or invokes the supplied custom edit callback.
  Future<void> _openEditProfile() async {
    if (widget.onEditProfile != null) {
      widget.onEditProfile!();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(
          initialName: _name,
          initialPhone: _phone,
          email: widget.userProfile.email,
          avatarImageUrl: _avatarUrl,
        ),
      ),
    );
  }

  /// Opens the photo picker unless a custom photo action was supplied.
  Future<void> _changePhoto() async {
    if (widget.onChangePhoto != null) {
      widget.onChangePhoto!();
      return;
    }
    if (_uploadingPhoto) return;

    setState(() => _uploadingPhoto = true);
    await changeProfilePhoto(context, hasPhoto: _avatarUrl != null);
    if (mounted) setState(() => _uploadingPhoto = false);
  }

  void _openEmergencyContacts() {
    if (widget.onEmergencyContacts != null) {
      widget.onEmergencyContacts!();
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const EmergencyContactsScreen()));
  }

  void _openSettings() {
    if (widget.onSettings != null) {
      widget.onSettings!();
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  // ------------------------------------------------------------
  // BUILD
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(
        backgroundColor: RPColors.bg,
        elevation: 0,
        title: const Text(
          'Profile',
          style: TextStyle(
            color: RPColors.teal,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            children: [
              _buildAvatar(),
              const SizedBox(height: 16),
              Text(
                _name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: RPColors.textDark,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _phone.isNotEmpty ? _phone : widget.userProfile.email,
                style: const TextStyle(fontSize: 14, color: RPColors.textGrey),
              ),
              const SizedBox(height: 14),
              if (_badges.isNotEmpty)
                _buildVerificationBadges()
              else
                _buildPendingVerificationNotice(),
              const SizedBox(height: 24),
              _buildMenuTile(
                icon: Icons.person_outline,
                label: 'Edit Profile',
                onTap: _openEditProfile,
              ),
              const SizedBox(height: 12),
              _buildMenuTile(
                icon: Icons.contact_page_outlined,
                label: 'Emergency Contacts',
                onTap: _openEmergencyContacts,
              ),
              const SizedBox(height: 12),
              _buildMenuTile(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onTap: _openSettings,
              ),
              const SizedBox(height: 28),
              _buildLogoutButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPendingVerificationNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: RPColors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_empty, size: 14, color: RPColors.orange),
          SizedBox(width: 6),
          Text(
            'Verification pending',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: RPColors.orange,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    final url = _avatarUrl;
    return SizedBox(
      width: 110,
      height: 110,
      child: Stack(
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: RPColors.teal, width: 3),
            ),
            padding: const EdgeInsets.all(6),
            child: CircleAvatar(
              backgroundColor: RPColors.teal,
              backgroundImage: url != null ? NetworkImage(url) : null,
              child: _uploadingPhoto
                  ? const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    )
                  : (url == null
                        ? const Icon(
                            Icons.person,
                            color: Colors.white,
                            size: 48,
                          )
                        : null),
            ),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: InkWell(
              onTap: _changePhoto,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: RPColors.teal, width: 1.5),
                ),
                child: const Icon(
                  Icons.camera_alt,
                  size: 16,
                  color: RPColors.teal,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationBadges() {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: _badges.map((label) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: RPColors.teal.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, size: 14, color: RPColors.teal),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: RPColors.teal,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildMenuTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: RPColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RPColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: RPColors.teal.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: RPColors.teal),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: RPColors.textDark,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: RPColors.textGrey),
          ],
        ),
      ),
    );
  }

  Widget _buildLogoutButton() {
    return InkWell(
      onTap: _handleLogout,
      borderRadius: BorderRadius.circular(8),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.logout, size: 18, color: Colors.red),
            SizedBox(width: 8),
            Text(
              'Logout',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need to log in again to continue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await FirebaseAuth.instance.signOut();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}
