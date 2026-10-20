import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'form_widgets.dart';
import 'passenger_home.dart' show RPColors;

// TODO: replace with your real support address.
const String _supportEmail = 'support@routepool.app';

const Map<String, String> _languages = {
  'en': 'English',
  'ms': 'Bahasa Malaysia',
  'zh': '中文',
};

/// Preferences are stored in users/{uid}.settings as
/// {notifications: bool, language: 'en' | 'ms' | 'zh'}.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notifications = true;
  String _language = 'en';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    try {
      if (uid != null) {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
        final settings = doc.data()?['settings'];

        if (settings is Map) {
          _notifications = settings['notifications'] as bool? ?? true;
          final lang = settings['language'] as String?;
          if (lang != null && _languages.containsKey(lang)) _language = lang;
        }
      }
    } catch (e) {
      debugPrint('Load settings error: $e');
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// Saves a partial settings change. Returns false if it failed.
  Future<bool> _saveSettings(Map<String, dynamic> changes) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'settings': changes,
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      debugPrint('Save settings error: $e');
      return false;
    }
  }

  Future<void> _toggleNotifications(bool value) async {
    final previous = _notifications;
    setState(() => _notifications = value); // optimistic

    final ok = await _saveSettings({'notifications': value});
    if (ok || !mounted) return;

    setState(() => _notifications = previous);
    _showMessage('Could not update notifications. Please try again.');
  }

  Future<void> _pickLanguage() async {
    final selected = await showModalBottomSheet<String>(
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
              'Language',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: RPColors.textDark,
              ),
            ),
            const SizedBox(height: 8),
            for (final entry in _languages.entries)
              ListTile(
                title: Text(entry.value),
                trailing: entry.key == _language
                    ? const Icon(Icons.check, color: RPColors.teal)
                    : null,
                onTap: () => Navigator.of(ctx).pop(entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (selected == null || selected == _language) return;

    final previous = _language;
    setState(() => _language = selected);

    final ok = await _saveSettings({'language': selected});
    if (ok || !mounted) return;

    setState(() => _language = previous);
    _showMessage('Could not change language. Please try again.');
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help and Support'),
        content: const Text(
          'Need a hand? Email us at $_supportEmail and we\'ll get back to '
          'you as soon as we can.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'RoutePool',
      applicationVersion: '1.0.0', // TODO: keep in sync with pubspec.yaml
      applicationLegalese: 'Your Ride. Your Route. Penang',
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)));
  }

  // ------------------------------------------------------------
  // BUILD
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Settings'),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  const _SectionHeader('PREFERENCES'),
                  _SettingsCard(
                    children: [
                      _SettingsRow(
                        icon: Icons.language,
                        label: 'Language',
                        value: _languages[_language],
                        onTap: _pickLanguage,
                      ),
                      const _RowDivider(),
                      _SettingsRow(
                        icon: Icons.notifications_none,
                        label: 'Notifications',
                        trailing: Switch(
                          value: _notifications,
                          onChanged: _toggleNotifications,
                          activeThumbColor: Colors.white,
                          activeTrackColor: RPColors.teal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _SectionHeader('SUPPORT'),
                  _SettingsCard(
                    children: [
                      _SettingsRow(
                        icon: Icons.help_outline,
                        label: 'Help and Support',
                        onTap: _showHelp,
                      ),
                      const _RowDivider(),
                      _SettingsRow(
                        icon: Icons.info_outline,
                        label: 'About RoutePool',
                        onTap: _showAbout,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

// ------------------------------------------------------------
// SMALL WIDGETS
// ------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: RPColors.textGrey,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, indent: 16, endIndent: 16);
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: RPColors.teal),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: RPColors.textDark,
                ),
              ),
            ),
            if (value != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  value!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: RPColors.textDark,
                  ),
                ),
              ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              const Icon(Icons.chevron_right, color: RPColors.textGrey),
          ],
        ),
      ),
    );
  }
}