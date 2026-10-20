import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/app_theme.dart';
import 'ic_upload_screen.dart';
import 'role_select_screen.dart';

class RejectedScreen extends StatefulWidget {
  final String? reason;
  final String? role;
  final int documentSubmissionAttempts;

  const RejectedScreen({
    super.key,
    this.reason,
    this.role,
    this.documentSubmissionAttempts = 0,
  });

  @override
  State<RejectedScreen> createState() => _RejectedScreenState();
}

class _RejectedScreenState extends State<RejectedScreen> {
  bool _isLoading = false;

  Future<void> _handleTryAgain() async {
    setState(() => _isLoading = true);

    final user = FirebaseAuth.instance.currentUser;

    try {
      if (user != null &&
          widget.role != null &&
          widget.documentSubmissionAttempts < 3) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({
              'verificationStatus': 'pending',
              'rejectionReason': FieldValue.delete(),
            });

        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => IcUploadScreen(role: widget.role!)),
          (route) => false,
        );
        return;
      }

      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .delete();
        await user.delete();
      }
    } catch (e) {
      await FirebaseAuth.instance.signOut();
    }

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleSelectScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.offWhite,
      body: Column(
        children: [
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
                        Icons.cancel_outlined,
                        color: Colors.redAccent,
                        size: 44,
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(0, -35),
                    child: Column(
                      children: [
                        const Text(
                          'Registration not approved',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (widget.reason != null &&
                            widget.reason!.isNotEmpty) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.red.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Reason:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                    color: Colors.red.shade700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.reason!,
                                  style: TextStyle(
                                    color: Colors.red.shade700,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          widget.documentSubmissionAttempts < 3
                              ? 'Please submit clearer or corrected documents. You have ${3 - widget.documentSubmissionAttempts} resubmission${3 - widget.documentSubmissionAttempts == 1 ? '' : 's'} remaining.'
                              : 'You have reached the document resubmission limit. Please register again with a new application.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.black54,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _handleTryAgain,
                            child: _isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(
                                    widget.documentSubmissionAttempts < 3
                                        ? 'Resubmit Documents'
                                        : 'Start New Application',
                                  ),
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
      ),
    );
  }
}
