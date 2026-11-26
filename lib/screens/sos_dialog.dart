import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import 'passenger_home.dart' show RPColors;

/// Saves an SOS report and offers SMS and dialer actions for saved contacts.
/// Neither SMS nor phone calls are initiated without user action.
Future<void> showSosDialog(BuildContext context, {required String tripId}) {
  if (tripId.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trip information is unavailable.')),
    );
    return Future<void>.value();
  }

  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SosDialog(tripId: tripId),
  );
}

class _SosDialog extends StatefulWidget {
  const _SosDialog({required this.tripId});

  final String tripId;

  @override
  State<_SosDialog> createState() => _SosDialogState();
}

class _SosDialogState extends State<_SosDialog> {
  static const _smsChannel = MethodChannel('routepool/sms');
  static const _cooldown = Duration(seconds: 60);
  static final Map<String, DateTime> _lastSosByUserAndTrip = {};
  static final Set<String> _activeSosByUserAndTrip = {};
  Timer? _cooldownTimer;
  int _remainingCooldownSeconds = 0;

  bool _contactsVisible = false;
  bool _contactsLoading = true;
  bool _reportPreparing = false;
  bool _reportSaved = false;
  bool _trackingPreparing = false;
  bool _locationUnavailable = false;
  bool _trackingUnavailable = false;
  bool _preparationStarted = false;

  String? _locationUrl;
  String? _trackingUrl;
  String? _error;
  String? _contactsError;

  List<Map<String, String>> _emergencyContacts = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadEmergencyContacts());
    _startCooldownTimer();
  }

  void _updateCooldown() {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) return;

    final key = '$uid:${widget.tripId}';
    final lastSos = _lastSosByUserAndTrip[key];

    if (lastSos == null) {
      if (mounted) {
        setState(() => _remainingCooldownSeconds = 0);
      }
      return;
    }

    final remaining = _cooldown - DateTime.now().difference(lastSos);

    final seconds = remaining.inMilliseconds <= 0
        ? 0
        : (remaining.inMilliseconds / 1000).ceil();

    if (mounted) {
      setState(() => _remainingCooldownSeconds = seconds);
    }
  }

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _updateCooldown();

    if (_remainingCooldownSeconds == 0) return;

    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateCooldown();

      if (_remainingCooldownSeconds == 0) {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<Position?> _tryGetLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadEmergencyContacts() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) {
        setState(() {
          _contactsLoading = false;
          _contactsError = 'Please sign in to load emergency contacts.';
        });
      }
      return;
    }

    try {
      final userSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final rawContacts = userSnapshot.data()?['emergencyContacts'];
      final contacts = rawContacts is List
          ? rawContacts
                .whereType<Map>()
                .map(
                  (contact) => <String, String>{
                    'name': (contact['name'] ?? '').toString().trim(),
                    'phone': (contact['phone'] ?? '').toString().trim(),
                  },
                )
                .where((contact) => _isValidPhone(contact['phone']!))
                .toList()
          : <Map<String, String>>[];

      if (!mounted) return;
      setState(() {
        _emergencyContacts = contacts;
        _contactsLoading = false;
        if (contacts.isEmpty) {
          _contactsError =
              'No valid emergency contacts are saved. Add them in '
              'Profile > Emergency Contacts.';
        }
      });
    } catch (error) {
      debugPrint('SOS emergency contacts unavailable: $error');
      if (!mounted) return;
      setState(() {
        _contactsLoading = false;
        _contactsError =
            'Could not load emergency contacts. You can still contact '
            'emergency services directly.';
      });
    }
  }

  bool _isValidPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 8 && digits.length <= 15;
  }

  /// Reuses the public tracking service from Share Trip.
  Future<String?> _tryCreateTrackingLink() async {
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
          .httpsCallable('createPublicTripShare');

      final result = await callable
          .call(<String, dynamic>{'tripId': widget.tripId})
          .timeout(const Duration(seconds: 15));

      final data = result.data;
      final token = data is Map ? data['token'] : null;

      if (token is! String || token.isEmpty) return null;

      return 'https://routepool-9405b.web.app/track#$token';
    } catch (error) {
      debugPrint('SOS tracking link unavailable: $error');
      return null;
    }
  }

  String get _smsMessage {
    final lines = <String>['ROUTEPOOL SOS', 'I need help.'];
    if (_locationUrl != null) lines.add('My location: $_locationUrl');
    if (_trackingUrl != null) lines.add('Live tracking: $_trackingUrl');
    return lines.join('\n');
  }

  void _showContactsAndPrepareReport() {
    setState(() => _contactsVisible = true);
    _startReportPreparation();
  }

  void _startReportPreparation() {
    if (_preparationStarted) return;
    _preparationStarted = true;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _error = 'Please sign in before saving an SOS report.');
      return;
    }

    final cooldownKey = '$uid:${widget.tripId}';
    final lastSos = _lastSosByUserAndTrip[cooldownKey];
    if (lastSos != null) {
      final remaining = _cooldown - DateTime.now().difference(lastSos);
      if (remaining > Duration.zero) {
        setState(
          () => _error =
              'An SOS report was saved recently. Please wait '
              '${remaining.inSeconds + 1} seconds before saving another. '
              'You can still use SMS or Call below.',
        );
        return;
      }
      _lastSosByUserAndTrip.remove(cooldownKey);
    }
    if (!_activeSosByUserAndTrip.add(cooldownKey)) {
      setState(
        () => _error =
            'An SOS report is already being prepared. You can still use '
            'SMS or Call below.',
      );
      return;
    }

    setState(() {
      _reportPreparing = true;
      _trackingPreparing = true;
      _error = null;
    });
    unawaited(_prepareTrackingLink());
    unawaited(_prepareAndSaveReport(uid, cooldownKey));
  }

  Future<void> _prepareTrackingLink() async {
    final trackingUrl = await _tryCreateTrackingLink();
    if (!mounted) return;
    setState(() {
      _trackingUrl = trackingUrl;
      _trackingPreparing = false;
      _trackingUnavailable = trackingUrl == null;
    });
  }

  Future<void> _prepareAndSaveReport(String uid, String cooldownKey) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final locationFuture = _tryGetLocation();
      final tripSnapshot = await firestore
          .collection('trips')
          .doc(widget.tripId)
          .get();
      final trip = tripSnapshot.data();
      if (trip == null) {
        throw StateError('This trip could not be found.');
      }

      final isDriver = trip['driverId'] == uid;
      final passengerIds = trip['passengerIds'];
      final isPassenger = passengerIds is List && passengerIds.contains(uid);
      if (!isDriver && !isPassenger) {
        throw StateError('You are not a participant in this trip.');
      }

      final position = await locationFuture;
      final locationUrl = position == null
          ? null
          : 'https://maps.google.com/?q='
                '${position.latitude},${position.longitude}';
      if (mounted) {
        setState(() {
          _locationUrl = locationUrl;
          _locationUnavailable = position == null;
        });
      }
      if (FirebaseAuth.instance.currentUser?.uid != uid) {
        throw StateError(
          'Your sign-in changed before the SOS report was saved.',
        );
      }

      await firestore.collection('sos_alerts').add({
        'userId': uid,
        'tripId': widget.tripId,
        'createdAt': FieldValue.serverTimestamp(),
        'location': position == null
            ? null
            : GeoPoint(position.latitude, position.longitude),
        'locationAccuracyMeters': position?.accuracy,
      });

      _lastSosByUserAndTrip[cooldownKey] = DateTime.now();

      if (mounted) {
        setState(() {
          _reportPreparing = false;
          _reportSaved = true;
        });

        _startCooldownTimer();
      }
    } catch (error) {
      debugPrint('SOS report could not be saved: $error');

      _preparationStarted = false;

      if (mounted) {
        setState(() {
          _reportPreparing = false;
          _error =
              'SOS report could not be saved: $error. You can still use '
              'SMS or Call below.';
        });
      }
    } finally {
      _activeSosByUserAndTrip.remove(cooldownKey);
    }
  }

  Future<void> _openSms(Map<String, String> contact, String message) async {
    final phone = contact['phone']!.replaceAll(RegExp(r'[^0-9+]'), '');

    if (!_isValidPhone(phone)) {
      throw StateError('Invalid emergency contact phone number.');
    }

    try {
      // Native Android SMS composer via MainActivity.kt.
      await _smsChannel.invokeMethod<bool>('openSms', {
        'phone': phone,
        'message': message,
      });
    } on MissingPluginException {
      // Fallback when the native handler is unavailable.
      final uri = Uri.parse('sms:$phone?body=${Uri.encodeComponent(message)}');

      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);

      if (!opened) {
        throw StateError('No SMS application is available.');
      }
    }
  }

  Future<void> _callContact(Map<String, String> contact) async {
    final phone = (contact['phone'] ?? '').replaceAll(RegExp(r'[^0-9+]'), '');

    if (!_isValidPhone(phone)) {
      if (mounted) {
        setState(() {
          _error = 'Invalid emergency contact phone number.';
        });
      }
      return;
    }

    try {
      final opened = await launchUrl(
        Uri(scheme: 'tel', path: phone),
        mode: LaunchMode.externalApplication,
      );

      if (!opened) {
        throw StateError('No phone dialer is available.');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not open the dialer: $error';
        });
      }
    }
  }

  Future<void> _messageContact(Map<String, String> contact) async {
    try {
      await _openSms(contact, _smsMessage);
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not open SMS for ${contact['name']}: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: RPColors.cardBg,
      title: const Row(
        children: [
          Icon(Icons.shield_outlined, color: RPColors.danger),
          SizedBox(width: 10),
          Expanded(child: Text('SOS Safety Report')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'If you are in immediate danger, contact local '
              'emergency services directly. '
              'This feature does not call them.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Choose a saved contact to open Messages or the phone dialer. '
              'An SOS report and any available location links are prepared '
              'in the background.',
            ),
            if (_contactsVisible) ...[
              const SizedBox(height: 14),
              if (_reportPreparing) ...[
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Expanded(child: Text('Saving SOS report in background...')),
                  ],
                ),
                const SizedBox(height: 8),
              ] else if (_reportSaved) ...[
                const Text(
                  'SOS report saved.',
                  style: TextStyle(
                    color: RPColors.teal,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (_trackingPreparing) ...[
                const Text('Preparing temporary tracking link...'),
                const SizedBox(height: 8),
              ],
              if (_contactsLoading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Loading saved emergency contacts...'),
              ] else if (_emergencyContacts.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Emergency Contacts',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text('Choose a contact and how you want to reach them.'),
                const SizedBox(height: 8),
                for (final contact in _emergencyContacts)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(
                        contact['name']!.isEmpty
                            ? 'Emergency Contact'
                            : contact['name']!,
                      ),
                      subtitle: Text(contact['phone']!),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Prepare SMS',
                            icon: const Icon(Icons.sms_outlined),
                            onPressed: () => _messageContact(contact),
                          ),
                          IconButton(
                            tooltip: 'Call contact',
                            icon: const Icon(Icons.call_outlined),
                            onPressed: () => _callContact(contact),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'SMS uses links ready when you tap SMS. If preparation is '
                  'still in progress, a basic SOS message opens immediately. '
                  'Press Send in Messages or Call in the dialer yourself.',
                ),
              ],
              if (!_contactsLoading && _contactsError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _contactsError!,
                  style: const TextStyle(color: RPColors.danger),
                ),
              ],
              if (_locationUnavailable) ...[
                const SizedBox(height: 8),
                const Text('GPS location was unavailable.'),
              ],
              if (_trackingUnavailable) ...[
                const SizedBox(height: 8),
                const Text(
                  'Live tracking could not be created. '
                  'You can still use SMS or Call; any available location '
                  'link is included.',
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: const TextStyle(color: RPColors.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),

        ElevatedButton(
          onPressed:
              (_remainingCooldownSeconds > 0 ||
                  _reportPreparing ||
                  _reportSaved ||
                  _preparationStarted)
              ? null
              : _showContactsAndPrepareReport,

          style: ElevatedButton.styleFrom(
            backgroundColor: RPColors.danger,
            foregroundColor: Colors.white,
          ),

          child: Text(
            _remainingCooldownSeconds > 0
                ? 'Wait ${_remainingCooldownSeconds}s'
                : _reportPreparing
                ? 'Preparing SOS...'
                : _reportSaved
                ? 'SOS Report Saved'
                : 'Alert Contacts',
          ),
        ),
      ],
    );
  }
}
