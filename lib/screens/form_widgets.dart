import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;

/// Small bold label shown above a text field.
class RPFieldLabel extends StatelessWidget {
  const RPFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: RPColors.textDark,
        ),
      ),
    );
  }
}

/// Consistent text field styling for all RoutePool forms.
InputDecoration rpInputDecoration({String? hint, bool readOnly = false}) {
  OutlineInputBorder border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: color),
  );

  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: RPColors.textGrey, fontSize: 14),
    filled: true,
    fillColor: readOnly ? RPColors.bg : const Color(0xFFF9FAFA),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: border(RPColors.border),
    disabledBorder: border(RPColors.border),
    focusedBorder: border(RPColors.teal),
    errorBorder: border(Colors.red),
    focusedErrorBorder: border(Colors.red),
  );
}

/// App bar used by the Edit Profile, Emergency Contacts and Settings pages.
PreferredSizeWidget rpAppBar(String title) {
  return AppBar(
    backgroundColor: RPColors.bg,
    elevation: 0,
    scrolledUnderElevation: 0,
    foregroundColor: RPColors.teal,
    centerTitle: true,
    title: Text(
      title,
      style: const TextStyle(
        color: RPColors.teal,
        fontWeight: FontWeight.w700,
        fontSize: 18,
      ),
    ),
  );
}

/// Full-width teal primary button with a loading state.
class RPPrimaryButton extends StatelessWidget {
  const RPPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: RPColors.teal,
          foregroundColor: Colors.white,
          disabledBackgroundColor: RPColors.teal.withValues(alpha: 0.6),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
