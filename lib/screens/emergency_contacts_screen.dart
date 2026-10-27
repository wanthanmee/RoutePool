import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'form_widgets.dart';
import 'passenger_home.dart' show RPColors;

const int _kMaxContacts = 3;

/// One editable contact card (its own controllers + a stable key).
class _ContactEntry {
  final TextEditingController name = TextEditingController();
  final TextEditingController phone = TextEditingController();
  final Key key = UniqueKey();

  bool get isEmpty => name.text.trim().isEmpty && phone.text.trim().isEmpty;

  void dispose() {
    name.dispose();
    phone.dispose();
  }
}

/// Stored in users/{uid}.emergencyContacts as a list of {name, phone} maps.
/// Lets the signed-in user manage up to three emergency contacts.
class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() =>
      _EmergencyContactsScreenState();
}

/// Loads, validates, and saves the editable emergency-contact entries.
class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  final _formKey = GlobalKey<FormState>();
  final List<_ContactEntry> _entries = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final e in _entries) {
      e.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------
  // LOAD / SAVE
  // ------------------------------------------------------------

  /// Loads saved contacts from the current user's Firestore profile.
  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    try {
      if (uid != null) {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
        final raw = doc.data()?['emergencyContacts'];

        if (raw is List) {
          for (final item in raw.take(_kMaxContacts)) {
            if (item is Map) {
              final entry = _ContactEntry();
              entry.name.text = (item['name'] ?? '').toString();
              entry.phone.text = (item['phone'] ?? '').toString();
              _entries.add(entry);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Load emergency contacts error: $e');
      if (mounted) _showMessage('Could not load your saved contacts.');
    }

    if (_entries.isEmpty) _entries.add(_ContactEntry());

    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// Validates and saves the non-empty contact entries to Firestore.
  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _showMessage('You are not signed in.');
      return;
    }

    final contacts = _entries
        .where((e) => !e.isEmpty)
        .map((e) => {'name': e.name.text.trim(), 'phone': e.phone.text.trim()})
        .toList();

    setState(() => _saving = true);

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'emergencyContacts': contacts,
      }, SetOptions(merge: true));

      if (!mounted) return;
      _showMessage(
        contacts.isEmpty ? 'Emergency contacts cleared.' : 'Contacts saved.',
      );
      Navigator.of(context).pop();
    } catch (e) {
      debugPrint('Save emergency contacts error: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      _showMessage('Could not save your contacts. Please try again.');
    }
  }

  // ------------------------------------------------------------
  // ADD / REMOVE
  // ------------------------------------------------------------

  void _addContact() {
    if (_entries.length >= _kMaxContacts) return;
    setState(() => _entries.add(_ContactEntry()));
  }

  void _removeContact(int index) {
    if (_entries.length == 1) {
      // Keep one card on screen; just clear it.
      _entries[0].name.clear();
      _entries[0].phone.clear();
      _formKey.currentState?.reset();
      return;
    }

    final removed = _entries[index];
    setState(() => _entries.removeAt(index));
    // Dispose after the frame so the removed field is fully unmounted first.
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
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
      appBar: rpAppBar('Emergency Contacts'),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Secure Your Journey',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: RPColors.textDark,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'These contacts will be notified if you '
                              'trigger SOS during a ride.',
                              style: TextStyle(
                                fontSize: 13,
                                color: RPColors.textGrey,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildNotice(),
                            const SizedBox(height: 16),
                            for (int i = 0; i < _entries.length; i++)
                              _buildCard(i, _entries[i]),
                            if (_entries.length < _kMaxContacts)
                              _buildAddButton(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                    child: RPPrimaryButton(
                      label: 'Save Contacts',
                      icon: Icons.check_circle_outline,
                      loading: _saving,
                      onPressed: _save,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildNotice() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: RPColors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: RPColors.orange.withValues(alpha: 0.35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Color(0xFF8A5A00)),
          SizedBox(width: 8),
          Text(
            'Maximum $_kMaxContacts emergency contacts',
            style: TextStyle(fontSize: 13, color: Color(0xFF8A5A00)),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(int index, _ContactEntry entry) {
    return Container(
      key: entry.key,
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: RPColors.bg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Contact #${index + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: RPColors.textGrey,
                  ),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => _removeContact(index),
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, size: 16, color: Colors.red),
                      SizedBox(width: 4),
                      Text(
                        'Remove',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const RPFieldLabel('Full Name'),
          TextFormField(
            controller: entry.name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: rpInputDecoration(hint: 'e.g. David Smith'),
            validator: (value) {
              final empty = (value ?? '').trim().isEmpty;
              if (empty && entry.phone.text.trim().isNotEmpty) {
                return 'Please enter a name.';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          const RPFieldLabel('Phone Number'),
          TextFormField(
            controller: entry.phone,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s()]')),
            ],
            decoration: rpInputDecoration(hint: 'e.g. +60 12-345 6789'),
            validator: (value) {
              final v = (value ?? '').trim();
              if (v.isEmpty) {
                if (entry.name.text.trim().isNotEmpty) {
                  return 'Please enter a phone number.';
                }
                return null;
              }
              final digits = v.replaceAll(RegExp(r'\D'), '');
              if (digits.length < 8 || digits.length > 15) {
                return 'Enter a valid phone number.';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAddButton() {
    return InkWell(
      onTap: _addContact,
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        painter: _DashedRRectPainter(RPColors.teal.withValues(alpha: 0.5)),
        child: const SizedBox(
          width: double.infinity,
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline, size: 18, color: RPColors.teal),
              SizedBox(width: 8),
              Text(
                'Add Contact',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: RPColors.teal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws a dashed rounded-rectangle border (no extra package needed).
/// Paints a rounded dashed outline around an emergency-contact card.
class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      );

    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 6), paint);
        distance += 10;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color;
}