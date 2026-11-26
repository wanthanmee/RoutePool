import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:share_plus/share_plus.dart';

import 'passenger_home.dart' show RPColors;

/// Shares a trip summary with a short-lived public link to driver live location.
Future<void> showShareTripSheet(
  BuildContext context, {
  required String pickupName,
  required String destination,
  String? driverName,
  String? tripId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: RPColors.cardBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ShareTripSheet(
      pickupName: pickupName,
      destination: destination,
      driverName: driverName,
      tripId: tripId,
    ),
  );
}

class _ShareTripSheet extends StatefulWidget {
  const _ShareTripSheet({
    required this.pickupName,
    required this.destination,
    this.driverName,
    this.tripId,
  });

  final String pickupName;
  final String destination;
  final String? driverName;
  final String? tripId;

  @override
  State<_ShareTripSheet> createState() => _ShareTripSheetState();
}

class _ShareTripSheetState extends State<_ShareTripSheet> {
  String? _shareLink;
  bool _creatingLink = false;

  String get _message {
    final link = _shareLink;
    final destinations = widget.destination
        .split('\n')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .map((item) => '- $item');
    final lines = <String>[
      'RoutePool trip update',
      'Pickup: ${widget.pickupName.trim()}',
      'Destinations:',
      ...destinations,
    ];
    if (widget.driverName != null && widget.driverName!.trim().isNotEmpty) {
      lines.add('Driver: ${widget.driverName!.trim()}');
    }
    if (link != null) {
      lines.add('Live trip location (expires in 2 hours): $link');
    } else if (widget.tripId != null && widget.tripId!.trim().isNotEmpty) {
      lines.add('Trip reference: ${widget.tripId!.trim()}');
    }
    lines.add('Shared via RoutePool.');
    return lines.join('\n');
  }

  String get _summaryWithoutLink {
    final destinations = widget.destination
        .split('\n')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .map((item) => '- $item')
        .join('\n');
    return 'Pickup: ${widget.pickupName.trim()}\n'
        'Destinations:\n$destinations\n'
        'A live tracking link will be created when you share.';
  }

  Future<void> _createShareLink() async {
    if (_shareLink != null || _creatingLink) return;
    final tripId = widget.tripId;
    if (tripId == null || tripId.trim().isEmpty) {
      throw StateError('Trip information is unavailable.');
    }

    setState(() => _creatingLink = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
          .httpsCallable('createPublicTripShare');
      final result = await callable.call(<String, dynamic>{'tripId': tripId});
      final data = result.data;
      final token = data is Map ? data['token'] : null;
      if (token is! String || token.isEmpty) {
        throw StateError('The tracking service returned an invalid link.');
      }
      if (!mounted) return;
      setState(() {
        _shareLink = 'https://routepool-9405b.web.app/track#$token';
      });
    } finally {
      if (mounted) setState(() => _creatingLink = false);
    }
  }

  Future<void> _share(BuildContext context) async {
    try {
      await _createShareLink();
      if (!context.mounted) return;
      await SharePlus.instance.share(ShareParams(text: _message));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare trip sharing: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: RPColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Share Your Trip',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: RPColors.teal,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Anyone with the live link can see the driver’s location while the trip is active. The link expires after 2 hours.',
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: RPColors.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: RPColors.border),
                ),
                child: SelectableText(
                  _shareLink == null ? _summaryWithoutLink : _message,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _creatingLink ? null : () => _share(context),
                  icon: const Icon(Icons.share_outlined),
                  label: Text(
                    _creatingLink
                        ? 'Creating secure link...'
                        : 'Create and Share Live Trip Link',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _creatingLink
                      ? null
                      : () async {
                          try {
                            await _createShareLink();
                            await Clipboard.setData(
                              ClipboardData(text: _message),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Live trip link and details copied.',
                                ),
                              ),
                            );
                          } catch (error) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Could not copy trip link: $error',
                                ),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Create and Copy Live Link'),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
