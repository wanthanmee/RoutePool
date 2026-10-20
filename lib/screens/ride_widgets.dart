import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;

/// Pale teal used for chips and highlighted rows.
Color get rpTealTint => RPColors.teal.withValues(alpha: 0.1);

/// Deep red for destructive driver actions (End Ride, Confirm Cancellation).
/// Could move into RPColors later.
const rpDangerDeep = Color(0xFFB91C1C);

/// White rounded card with a soft shadow.
class RPCard extends StatelessWidget {
  const RPCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: RPColors.cardBg,
      borderRadius: BorderRadius.circular(14),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: child,
  );
}

/// Teal avatar circle with an optional orange rating badge.
class RPAvatar extends StatelessWidget {
  const RPAvatar({super.key, this.size = 44, this.rating});

  final double size;
  final String? rating;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      CircleAvatar(
        radius: size / 2,
        backgroundColor: RPColors.teal,
        child: Icon(
          Icons.person_outline,
          color: Colors.white,
          size: size * 0.6,
        ),
      ),
      if (rating != null)
        Positioned(
          bottom: -4,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: RPColors.orange,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '★ $rating',
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Circular chat / call button.
class RPRoundIconButton extends StatelessWidget {
  const RPRoundIconButton(
    this.icon, {
    super.key,
    this.filled = true,
    this.onTap,
  });

  final IconData icon;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    customBorder: const CircleBorder(),
    onTap: onTap ?? () {},
    child: Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? RPColors.teal : rpTealTint,
        border: filled ? null : Border.all(color: RPColors.border),
      ),
      child: Icon(icon, size: 18, color: filled ? Colors.white : RPColors.teal),
    ),
  );
}

/// Number plate box (RP-2024).
class RPPlateBox extends StatelessWidget {
  const RPPlateBox({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: RPColors.cardBg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: RPColors.border),
    ),
    child: const Text(
      'RP-\n2024',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: RPColors.textDark,
        height: 1.2,
      ),
    ),
  );
}

/// Small uppercase grey label.
class RPSectionLabel extends StatelessWidget {
  const RPSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      letterSpacing: 0.8,
      fontWeight: FontWeight.w600,
      color: RPColors.textGrey,
    ),
  );
}

/// Label on the left, value on the right.
class RPFareRow extends StatelessWidget {
  const RPFareRow(this.label, this.value, {super.key, this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      color: RPColors.textDark,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: style),
        Text(value, style: style),
      ],
    );
  }
}

/// Full-width orange button (Share Trip Details, Done, Confirm and Pay).
class RPAccentButton extends StatelessWidget {
  const RPAccentButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 52,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: height,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: RPColors.orange,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ],
      ),
    ),
  );
}
