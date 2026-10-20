import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'passenger_home.dart' show RPColors;
import 'ride_mock_data.dart';
import 'ride_widgets.dart';

Future<void> showShareTripSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: RPColors.cardBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const _ShareTripSheet(),
  );
}

class _ShareTripSheet extends StatelessWidget {
  const _ShareTripSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
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
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: rpTealTint,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: RPColors.teal.withValues(alpha: 0.2)),
            ),
            child: const Text(
              rideShareMessage,
              style: TextStyle(
                fontSize: 13,
                color: RPColors.textDark,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ShareOption(
                icon: Icons.share,
                label: 'WhatsApp',
                bg: const Color(0xFFDDF5E6),
                fg: const Color(0xFF25A55A),
                // TODO: launchUrl(Uri.parse(
                //   'https://wa.me/?text=${Uri.encodeComponent(rideShareMessage)}'))
                onTap: () {},
              ),
              _ShareOption(
                icon: Icons.chat_bubble,
                label: 'SMS',
                bg: const Color(0xFFDCE9FB),
                fg: const Color(0xFF2F6FDE),
                // TODO: launchUrl(Uri(scheme: 'sms',
                //   queryParameters: {'body': rideShareMessage}))
                onTap: () {},
              ),
              _ShareOption(
                icon: Icons.link,
                label: 'Copy Link',
                bg: const Color(0xFFE6E8E9),
                fg: RPColors.textGrey,
                onTap: () async {
                  await Clipboard.setData(
                    const ClipboardData(text: rideShareLink),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied')),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 22),
          RPAccentButton(
            label: 'Done',
            height: 50,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    ),
  );
}

class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, color: fg),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: RPColors.textDark),
        ),
      ],
    ),
  );
}