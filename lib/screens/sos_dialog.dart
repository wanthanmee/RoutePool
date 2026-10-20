import 'dart:async';

import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;
import 'ride_widgets.dart';

Future<void> showSosDialog(BuildContext context) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    builder: (_) => const _SosDialog(),
  );
}

class _SosDialog extends StatefulWidget {
  const _SosDialog();

  @override
  State<_SosDialog> createState() => _SosDialogState();
}

class _SosDialogState extends State<_SosDialog> {
  static const _countdownSeconds = 5;

  int _remaining = _countdownSeconds;
  bool _sending = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        _triggerAlert();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _triggerAlert() {
    _timer?.cancel();
    setState(() {
      _remaining = 0;
      _sending = true;
    });
    _sendAlerts();
  }

  Future<void> _sendAlerts() async {
    // TODO: write to Firestore (e.g. sos_alerts/{id} with live location) and
    // notify emergency contacts through your Cloud Function.
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: RPColors.cardBg,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: RPColors.danger.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.shield, color: RPColors.danger, size: 28),
          ),
          const SizedBox(height: 14),
          const Text(
            'Are You in Danger?',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: RPColors.textDark,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your emergency contacts and RoutePool will be notified with '
            'your live location',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: RPColors.textGrey),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: 84,
            height: 84,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: _remaining / _countdownSeconds,
                    strokeWidth: 4,
                    color: RPColors.teal,
                    backgroundColor: rpTealTint,
                  ),
                ),
                Text(
                  '${_remaining}s',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: RPColors.teal,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: RPColors.danger,
                foregroundColor: Colors.white,
                disabledBackgroundColor: RPColors.danger,
                disabledForegroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              // Tapping early sends the alert immediately.
              onPressed: _sending ? null : _triggerAlert,
              child: Text(_sending ? 'Sending Alerts...' : 'Send Alert Now'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: RPColors.textDark,
                side: const BorderSide(color: RPColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    ),
  );
}