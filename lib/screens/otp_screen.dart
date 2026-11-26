import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/app_theme.dart';
import 'ic_upload_screen.dart';

/// Verifies a phone OTP and completes account registration.
class OtpScreen extends StatefulWidget {
  final String phoneNumber;
  final String role;
  final String verificationId;

  /// Firebase may omit the resend token on some platforms.
  final int? resendToken;
  final String fullName;
  final String email;
  final String password;

  const OtpScreen({
    super.key,
    required this.phoneNumber,
    required this.role,
    required this.verificationId,
    this.resendToken,
    required this.fullName,
    required this.email,
    required this.password,
  });

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  // -----------------------------------------------------------
  // OTP Input Controllers
  // -----------------------------------------------------------

  final List<TextEditingController> _controllers = List.generate(
    6,
    (_) => TextEditingController(),
  );

  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  // -----------------------------------------------------------
  // Form State
  // -----------------------------------------------------------

  bool _isLoading = false;
  bool _isResending = false;

  String? _errorText;

  // -----------------------------------------------------------
  // Firebase OTP State
  // -----------------------------------------------------------

  late String _currentVerificationId;
  int? _resendToken;
  // Advanced when a resend attempt settles so its late callbacks are ignored.
  int _resendRequestId = 0;

  // -----------------------------------------------------------
  // Resend OTP Cooldown
  // -----------------------------------------------------------

  static const int _cooldownSeconds = 30;

  int _resendCooldown = _cooldownSeconds;
  Timer? _cooldownTimer;

  // -----------------------------------------------------------
  // Initialize Screen
  // -----------------------------------------------------------

  @override
  void initState() {
    super.initState();

    _currentVerificationId = widget.verificationId;
    _resendToken = widget.resendToken;

    // Start cooldown immediately when OTP screen opens.
    _startCooldown();
  }

  // -----------------------------------------------------------
  // Start / Restart Cooldown
  // -----------------------------------------------------------

  void _startCooldown() {
    _cooldownTimer?.cancel();

    if (!mounted) return;

    setState(() {
      _resendCooldown = _cooldownSeconds;
    });

    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_resendCooldown <= 1) {
        timer.cancel();

        setState(() {
          _resendCooldown = 0;
        });
      } else {
        setState(() {
          _resendCooldown--;
        });
      }
    });
  }

  // -----------------------------------------------------------
  // Dispose Resources
  // -----------------------------------------------------------

  @override
  void dispose() {
    _cooldownTimer?.cancel();

    for (final controller in _controllers) {
      controller.dispose();
    }

    for (final focusNode in _focusNodes) {
      focusNode.dispose();
    }

    super.dispose();
  }

  // -----------------------------------------------------------
  // Verify OTP
  // -----------------------------------------------------------

  Future<void> _handleVerify() async {
    if (_isLoading || _isResending) return;

    final otp = _controllers.map((c) => c.text).join();

    if (otp.length != 6) {
      setState(() {
        _errorText = 'Please enter all 6 digits.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      // Step 1: Create phone authentication credential.
      // Use only the latest session confirmed by Firebase's codeSent callback.
      final phoneCredential = PhoneAuthProvider.credential(
        verificationId: _currentVerificationId,
        smsCode: otp,
      );

      // Step 2: Verify phone number with Firebase.
      // This creates or signs into a phone Auth account.
      final phoneSignIn = await FirebaseAuth.instance.signInWithCredential(
        phoneCredential,
      );

      final phoneUser = phoneSignIn.user;

      if (phoneUser == null) {
        throw FirebaseAuthException(
          code: 'user-not-found',
          message: 'Unable to verify phone account.',
        );
      }

      // Step 3: Link email and password to verified phone account.
      final emailCredential = EmailAuthProvider.credential(
        email: widget.email,
        password: widget.password,
      );

      final userCredential = await phoneUser.linkWithCredential(
        emailCredential,
      );

      final uid = userCredential.user!.uid;

      // Step 4: Save user profile in Firestore.
      // This happens only after successful OTP verification.
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name': widget.fullName,
        'email': widget.email,
        'phoneNo': widget.phoneNumber,
        'role': widget.role,
        'verificationStatus': 'pending',
        'phoneVerified': true,
        'icPassport': '',
        'documentSubmissionAttempts': 0,
        'profilePic': '',
        if (widget.role == 'driver') 'driverApproved': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      debugPrint('OTP verified successfully.');
      debugPrint('Firestore user profile created.');

      if (!mounted) return;

      // Step 5: Continue to document verification.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => IcUploadScreen(role: widget.role)),
      );
    } on FirebaseAuthException catch (e) {
      debugPrint('OTP Verification Error: ${e.code} - ${e.message}');

      if (!mounted) return;

      setState(() {
        _isLoading = false;

        _errorText = switch (e.code) {
          'invalid-verification-code' => 'Incorrect OTP. Please try again.',
          'session-expired' => 'OTP expired. Please request a new code.',
          'email-already-in-use' =>
            'This email is already registered. Please log in instead.',
          'credential-already-in-use' =>
            'This phone number is already linked to another account.',
          'invalid-credential' =>
            'Invalid or expired OTP. Please request a new code.',
          _ => e.message ?? 'Verification failed.',
        };
      });
    } catch (e) {
      debugPrint('OTP Verification Exception: $e');

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _errorText = 'Something went wrong. Please try again.';
      });
    }
  }

  // -----------------------------------------------------------
  // Resend OTP
  // -----------------------------------------------------------

  Future<void> _handleResend() async {
    // Prevent resending during cooldown or active requests.
    if (_resendCooldown > 0 || _isResending || _isLoading) {
      return;
    }

    setState(() {
      _isResending = true;
      _errorText = null;
    });

    final requestId = ++_resendRequestId;
    final forceResendingToken = _resendToken;
    debugPrint(
      'Starting OTP resend request '
      '(resend token available: ${forceResendingToken != null}).',
    );

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: widget.phoneNumber,
        timeout: const Duration(seconds: 60),

        // Reuse Firebase resend token when available.
        forceResendingToken: forceResendingToken,

        // Automatic phone verification callback.
        verificationCompleted: (PhoneAuthCredential credential) {
          if (requestId != _resendRequestId) return;
          // Keep this registration flow on manual OTP entry.
          debugPrint(
            'Firebase automatically verified phone credentials during resend; '
            'manual OTP entry remains enabled.',
          );
        },

        // Called when Firebase rejects verification.
        verificationFailed: (FirebaseAuthException e) {
          if (requestId != _resendRequestId) return;
          _resendRequestId++;
          debugPrint('Resend OTP failed: ${e.code} - ${e.message}');

          if (!mounted) return;

          setState(() {
            _isResending = false;
            _errorText = _resendErrorMessage(e);
          });
        },

        // Called when Firebase accepts the new OTP request.
        codeSent: (String verificationId, int? resendToken) {
          if (requestId != _resendRequestId) return;
          // Only codeSent confirms a new session; retire this request's callbacks.
          _resendRequestId++;
          debugPrint(
            'Firebase confirmed resend codeSent '
            '(resend token available: ${resendToken != null}).',
          );
          debugPrint('Active verification session changed after resend.');
          if (!mounted) return;

          setState(() {
            _currentVerificationId = verificationId;

            // Some platforms omit a token; retain the latest one Firebase provided.
            if (resendToken != null) {
              _resendToken = resendToken;
            }

            _isResending = false;

            for (final controller in _controllers) {
              controller.clear();
            }
          });

          _startCooldown();

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Firebase accepted the new OTP request. Check your messages.',
              ),
            ),
          );
        },

        // Called when automatic code retrieval times out.
        codeAutoRetrievalTimeout: (String verificationId) {
          if (requestId != _resendRequestId) return;
          // End this request without replacing the active verification session.
          _resendRequestId++;
          debugPrint('Resend OTP auto-retrieval timed out.');
          if (!mounted) return;

          if (_isResending) {
            setState(() {
              _isResending = false;
              _errorText = 'Could not confirm a new OTP. Please try again.';
            });
          }
        },
      );
    } on FirebaseAuthException catch (e) {
      if (requestId != _resendRequestId) return;
      _resendRequestId++;
      debugPrint('Resend OTP request failed: ${e.code} - ${e.message}');

      if (!mounted) return;

      setState(() {
        _isResending = false;
        _errorText = _resendErrorMessage(e);
      });
    } catch (e) {
      if (requestId != _resendRequestId) return;
      _resendRequestId++;
      debugPrint('Resend OTP Exception: $e');

      if (!mounted) return;

      setState(() {
        _isResending = false;
        _errorText = 'Could not resend OTP. Please try again.';
      });
    }
  }

  String _resendErrorMessage(FirebaseAuthException e) {
    return switch (e.code) {
      'quota-exceeded' =>
        'SMS quota exceeded. Please try again later or contact support.',
      'too-many-requests' =>
        'Too many verification attempts. Please wait before trying again.',
      'invalid-phone-number' =>
        'The phone number is invalid. Please return and correct it.',
      'operation-not-allowed' =>
        'Phone verification is not enabled. Please contact support.',
      'billing-not-enabled' =>
        'SMS verification is unavailable right now. Please try again later.',
      'network-request-failed' =>
        'Network error. Check your connection and try again.',
      _ => e.message ?? 'Could not resend OTP. Please try again.',
    };
  }

  // -----------------------------------------------------------
  // Build OTP Screen
  // -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canResend = _resendCooldown == 0 && !_isResending && !_isLoading;

    return Scaffold(
      backgroundColor: AppColors.offWhite,

      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------------------------------------------------
          // Header
          // ---------------------------------------------------

          Container(
            width: double.infinity,
            color: AppColors.primaryTeal,
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),

            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => Navigator.of(context).pop(),

                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),

                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(20),
                    ),

                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_back_ios,
                          size: 14,
                          color: Colors.white,
                        ),
                        SizedBox(width: 4),
                        Text('Back', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                const Text(
                  'Enter OTP',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // ---------------------------------------------------
          // OTP Form
          // ---------------------------------------------------
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),

              child: Column(
                children: [
                  const SizedBox(height: 20),

                  const Text(
                    'OTP sent to',
                    style: TextStyle(color: Colors.black54, fontSize: 13),
                  ),

                  const SizedBox(height: 4),

                  Text(
                    widget.phoneNumber,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 20),

                  // -------------------------------------------
                  // Error Message
                  // -------------------------------------------
                  if (_errorText != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),

                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),

                      child: Text(
                        _errorText!,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 13,
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),
                  ],

                  // -------------------------------------------
                  // Six OTP Input Fields
                  // -------------------------------------------
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,

                    children: List.generate(6, (index) {
                      return SizedBox(
                        width: 45,
                        height: 55,

                        child: TextField(
                          controller: _controllers[index],
                          focusNode: _focusNodes[index],

                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,

                          maxLength: 1,

                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],

                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),

                          decoration: const InputDecoration(counterText: ''),

                          onChanged: (value) {
                            if (value.isNotEmpty && index < 5) {
                              _focusNodes[index + 1].requestFocus();
                            } else if (value.isEmpty && index > 0) {
                              _focusNodes[index - 1].requestFocus();
                            }
                          },
                        ),
                      );
                    }),
                  ),

                  const SizedBox(height: 20),

                  // -------------------------------------------
                  // Resend OTP with 30-Second Cooldown
                  // -------------------------------------------
                  GestureDetector(
                    onTap: canResend ? _handleResend : null,

                    child: Text(
                      _isResending
                          ? 'Sending OTP...'
                          : _resendCooldown > 0
                          ? 'Resend OTP in ${_resendCooldown}s'
                          : 'Resend OTP',

                      style: TextStyle(
                        color: canResend ? AppColors.accentAmber : Colors.grey,

                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  const Spacer(),

                  // -------------------------------------------
                  // Verify Button
                  // -------------------------------------------
                  SizedBox(
                    width: double.infinity,

                    child: ElevatedButton(
                      onPressed: (_isLoading || _isResending)
                          ? null
                          : _handleVerify,

                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,

                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Verify'),
                    ),
                  ),

                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
