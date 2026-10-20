import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/app_theme.dart';
import 'role_select_screen.dart';
import 'login_screen.dart';
import 'rejected_screen.dart';

/// Widget: VerificationScreen
/// -------------------------------------------------------------------
/// Shown to a user while their submitted documents are being reviewed.
///
/// Listens in real time to the user's Firestore profile and
/// automatically redirects to the appropriate screen once a decision
/// (approved / rejected) is made, or if the user's session/profile
/// disappears.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  // Ensures we only navigate away from this screen once, even if the
  // Firestore stream or auth listener fires multiple times.
  bool _hasNavigated = false;

  // Subscription to Firebase Auth state changes, used to detect if the
  // user gets signed out while waiting on this screen.
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();

    // Listen for sign-outs (e.g. session expiry) and send the user
    // back to role selection if that happens.
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) _signOutAndShowRoleSelection();
    });
  }

  @override
  void dispose() {
    // Clean up the auth listener when this screen is removed.
    _authSubscription?.cancel();
    super.dispose();
  }

  /// Replaces the current screen with [screen], guarding against
  /// duplicate navigation and running after the current frame so it's
  /// safe to call from inside `build`.
  void _replaceScreen(Widget screen) {
    if (_hasNavigated) return;
    _hasNavigated = true;
    final navigator = Navigator.of(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      navigator.pushReplacement(MaterialPageRoute(builder: (_) => screen));
    });
  }

  /// Signs the user out and sends them back to role selection,
  /// clearing the navigation stack. Used when the auth session ends
  /// or the user's profile no longer exists.
  void _signOutAndShowRoleSelection() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    final navigator = Navigator.of(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FirebaseAuth.instance.signOut();
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleSelectScreen()),
        (route) => false,
      );
    });
  }

  /// Builds the layout of the verification screen.
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: AppColors.offWhite,

      // Listen to the user's Firestore document so the UI reacts
      // immediately to status changes made by an admin/backend.
      body: StreamBuilder<DocumentSnapshot>(
        stream: uid == null
            ? null
            : FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            if (!snapshot.data!.exists) {
              // A missing profile means the account was deleted after the
              // final rejected submission, so start a fresh application.
              _signOutAndShowRoleSelection();
            } else {
              final data = snapshot.data!.data() as Map<String, dynamic>;
              final status = data['verificationStatus'];

              // Route the user based on the current verification status.
              if (status == 'approved') {
                _replaceScreen(const LoginScreen());
              } else if (status == 'rejected') {
                _replaceScreen(
                  RejectedScreen(
                    reason: data['rejectionReason'] as String?,
                    role: data['role'] as String?,
                    documentSubmissionAttempts:
                        (data['documentSubmissionAttempts'] as num?)?.toInt() ??
                        0,
                  ),
                );
              }
              // Any other status (e.g. "pending") keeps the user on
              // this waiting screen.
            }
          }

          // -----------------------------------------------------------
          // Waiting UI
          // -----------------------------------------------------------
          // Shown while the verification status is still pending.
          return Column(
            children: [
              // Teal header bar behind the floating icon badge.
              Container(
                width: double.infinity,
                height: 140,
                color: AppColors.primaryTeal,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Floating circular badge with a clock icon,
                      // overlapping the header and content below it.
                      Transform.translate(
                        offset: const Offset(0, -50),
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.access_time_rounded,
                            color: AppColors.primaryTeal,
                            size: 44,
                          ),
                        ),
                      ),

                      // Heading and status card, pulled up slightly to
                      // sit closer to the icon badge above.
                      Transform.translate(
                        offset: const Offset(0, -35),
                        child: Column(
                          children: [
                            // Heading text.
                            const Text(
                              "We're reviewing your\ndocuments",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            // Add spacing before the status card.
                            const SizedBox(height: 20),

                            // Card showing the review progress steps.
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppColors.gray),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: const [
                                  // Sets expectations on turnaround time.
                                  Text(
                                    'This usually takes 1-2 business days',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),

                                  // Add spacing before the step list.
                                  SizedBox(height: 16),

                                  // Step 1: documents have been submitted.
                                  _StatusRow(
                                    label: 'Documents submitted',
                                    state: _StepState.done,
                                  ),
                                  SizedBox(height: 12),

                                  // Step 2: currently in progress.
                                  _StatusRow(
                                    label: 'Under review',
                                    state: _StepState.active,
                                  ),
                                  SizedBox(height: 12),

                                  // Step 3: not yet reached.
                                  _StatusRow(
                                    label: 'Verification Complete',
                                    state: _StepState.pending,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The visual state of a single step in the review checklist.
enum _StepState { done, active, pending }

/// Widget: _StatusRow
/// -------------------------------------------------------------------
/// A single row in the review checklist, showing a status icon next
/// to a label. The icon and text colour change depending on whether
/// the step is done, active, or still pending.
class _StatusRow extends StatelessWidget {
  // Text describing this step.
  final String label;

  // Current state of this step (done / active / pending).
  final _StepState state;

  const _StatusRow({required this.label, required this.state});

  /// Builds the layout of a single status row.
  @override
  Widget build(BuildContext context) {
    late final Widget icon;
    late final Color textColor;

    // Pick the icon and text colour based on the step's state.
    switch (state) {
      case _StepState.done:
        // Completed step: filled teal check mark.
        icon = const Icon(
          Icons.check_circle,
          color: AppColors.primaryTeal,
          size: 18,
        );
        textColor = Colors.black87;
        break;
      case _StepState.active:
        // In-progress step: small amber dot.
        icon = const Icon(Icons.circle, color: AppColors.accentAmber, size: 12);
        textColor = Colors.black87;
        break;
      case _StepState.pending:
        // Not-yet-reached step: greyed-out outline circle and text.
        icon = const Icon(Icons.circle_outlined, color: Colors.grey, size: 16);
        textColor = Colors.grey;
        break;
    }

    return Row(
      children: [
        icon,

        // Add spacing between the icon and label.
        const SizedBox(width: 10),

        // Display the step label.
        Text(
          label,
          style: TextStyle(color: textColor, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
