import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_theme.dart';
import 'otp_screen.dart';

/// Widget: RegisterScreen
/// -------------------------------------------------------------------
/// Allows new users to create an account as either a passenger or driver.
///
/// The phone number is verified using an OTP before the account is created.
class RegisterScreen extends StatefulWidget {
  // Stores the role selected by the user.
  // Expected values are 'passenger' or 'driver'.
  final String role;

  const RegisterScreen({super.key, required this.role});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

/// Controls the registration form and registration process.
///
/// This class manages the user's input, validates the form, sends the
/// phone verification code, and navigates to the OTP verification screen.
class _RegisterScreenState extends State<RegisterScreen> {
  // -----------------------------------------------------------
  // Form Controllers
  // -----------------------------------------------------------
  // Controllers store and retrieve the text entered by the user
  // in each text field.

  final _fullNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // -----------------------------------------------------------
  // Form State
  // -----------------------------------------------------------

  // Controls whether the password is hidden or visible.
  bool _obscurePassword = true;

  // Controls whether the confirmation password is hidden or visible.
  bool _obscureConfirmPassword = true;

  // Tracks whether the registration process is currently running.
  // Used to disable the Register button and show a loading indicator.
  bool _isLoading = false;

  // Stores an error message to display to the user.
  // null means there is currently no error.
  String? _errorText;

  /// Releases the text controllers when the screen is removed.
  ///
  /// This prevents the controllers from using memory after the screen
  /// is no longer needed.
  @override
  void dispose() {
    _fullNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();

    super.dispose();
  }

  /// Converts the entered phone number into Malaysian international format.
  String _formatPhoneNumber(String raw) {
    // Remove unnecessary spaces from the beginning and end.
    final trimmed = raw.trim();

    // If the number already starts with '+', keep it unchanged.
    if (trimmed.startsWith('+')) return trimmed;

    // If the number starts with 0, replace the 0 with Malaysia's +60 code.
    if (trimmed.startsWith('0')) {
      return '+60${trimmed.substring(1)}';
    }

    // Otherwise, add Malaysia's +60 country code.
    return '+60$trimmed';
  }

  /// Validates the registration form and starts phone verification.
  ///
  /// If the form is valid, Firebase sends an OTP to the user's phone
  /// number. The user is then taken to the OTP screen.
  Future<void> _handleRegister() async {
    // Clear any previous error message.
    setState(() => _errorText = null);

    // -----------------------------------------------------------
    // Basic Form Validation
    // -----------------------------------------------------------

    // Make sure all required fields have been filled in.
    if (_fullNameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
        _emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _errorText = 'Please fill in all fields.');

      return;
    }

    // Check whether the email contains an '@' symbol.
    if (!_emailController.text.trim().contains('@')) {
      setState(() => _errorText = 'Please enter a valid email address.');

      return;
    }

    // Check whether both password fields contain the same password.
    if (_passwordController.text != _confirmPasswordController.text) {
      setState(() => _errorText = 'Passwords do not match.');

      return;
    }

    // Check that the password has at least 6 characters.
    if (_passwordController.text.length < 6) {
      setState(() => _errorText = 'Password must be at least 6 characters.');

      return;
    }

    // Show the loading indicator and disable the Register button.
    setState(() => _isLoading = true);

    // Convert the phone number into the format required by Firebase.
    final formattedPhone = _formatPhoneNumber(_phoneController.text);

    // -----------------------------------------------------------
    // Firebase Phone Verification
    // -----------------------------------------------------------

    try {
      // Send an OTP to the user's phone number.
      //
      // The account and Firestore profile are created later,
      // after the user successfully completes OTP verification.
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formattedPhone,

        // Firebase will wait up to 60 seconds for verification.
        timeout: const Duration(seconds: 60),

        // Called if Firebase automatically verifies the phone number.
        verificationCompleted: (PhoneAuthCredential phoneCredential) {},

        // Called when Firebase cannot send the verification code.
        verificationFailed: (FirebaseAuthException e) {
          setState(() {
            _isLoading = false;

            // Display Firebase's error message if available.
            _errorText = e.message ?? 'Phone verification failed.';
          });
        },

        // Called when Firebase successfully sends the OTP.
        codeSent: (String verificationId, int? resendToken) {
          // Stop showing the loading indicator.
          setState(() => _isLoading = false);

          // Make sure this screen still exists before navigating.
          if (!mounted) return;

          // Navigate to the OTP verification screen.
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => OtpScreen(
                // Pass the formatted phone number to the OTP screen.
                phoneNumber: formattedPhone,

                // Pass the selected role to the OTP screen.
                role: widget.role,

                // Pass the verification ID needed to verify the OTP.
                verificationId: verificationId,

                // Pass the user's registration details to the OTP screen.
                fullName: _fullNameController.text.trim(),
                email: _emailController.text.trim(),
                password: _passwordController.text,
              ),
            ),
          );
        },

        // Called when Firebase's automatic OTP retrieval times out.
        codeAutoRetrievalTimeout: (String verificationId) {},
      );
    } catch (e) {
      // Handle unexpected errors during the registration process.
      setState(() {
        _isLoading = false;
        _errorText = 'Something went wrong. Please try again.';
      });
    }
  }

  /// Builds the registration screen.
  ///
  /// Displays the registration form, validation errors, password fields,
  /// Register button, and login option.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Set the screen background colour.
      backgroundColor: AppColors.offWhite,

      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          // -----------------------------------------------------------
          // Header Section
          // -----------------------------------------------------------
          // Displays the Back button and Create Account heading.
          Container(
            width: double.infinity,
            color: AppColors.primaryTeal,

            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),

            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                // Back button.
                // Returns the user to the previous screen.
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

                // Add space between the Back button and heading.
                const SizedBox(height: 16),

                // Page title.
                const Text(
                  'Create Account',

                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          // -----------------------------------------------------------
          // Registration Form
          // -----------------------------------------------------------
          // SingleChildScrollView allows the user to scroll through
          // the form when the keyboard or small screen reduces the
          // available space.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  // ---------------------------------------------------
                  // Error Message
                  // ---------------------------------------------------
                  // Only display the error box when an error exists.
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

                  // ---------------------------------------------------
                  // Full Name
                  // ---------------------------------------------------
                  _FieldLabel('FULL NAME'),

                  TextField(controller: _fullNameController),

                  const SizedBox(height: 16),

                  // ---------------------------------------------------
                  // Phone Number
                  // ---------------------------------------------------
                  _FieldLabel('PHONE NUMBER'),

                  TextField(
                    controller: _phoneController,

                    // Display the phone number keyboard.
                    keyboardType: TextInputType.phone,

                    decoration: const InputDecoration(
                      hintText: 'e.g. 0123456789',
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ---------------------------------------------------
                  // Email Address
                  // ---------------------------------------------------
                  _FieldLabel('EMAIL ADDRESS'),

                  TextField(
                    controller: _emailController,

                    // Display the email keyboard.
                    keyboardType: TextInputType.emailAddress,
                  ),

                  const SizedBox(height: 16),

                  // ---------------------------------------------------
                  // Password
                  // ---------------------------------------------------
                  _FieldLabel('PASSWORD'),

                  TextField(
                    controller: _passwordController,

                    // Hide or show the password based on the current state.
                    obscureText: _obscurePassword,

                    decoration: InputDecoration(
                      // Button for showing or hiding the password.
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),

                        onPressed: () {
                          // Toggle between hidden and visible password.
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ---------------------------------------------------
                  // Confirm Password
                  // ---------------------------------------------------
                  _FieldLabel('CONFIRM PASSWORD'),

                  TextField(
                    controller: _confirmPasswordController,

                    // Hide or show the confirmation password.
                    obscureText: _obscureConfirmPassword,

                    decoration: InputDecoration(
                      // Button for showing or hiding the password.
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureConfirmPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),

                        onPressed: () {
                          // Toggle password visibility.
                          setState(() {
                            _obscureConfirmPassword = !_obscureConfirmPassword;
                          });
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // ---------------------------------------------------
                  // Register Button
                  // ---------------------------------------------------
                  SizedBox(
                    width: double.infinity,

                    child: ElevatedButton(
                      // Disable the button while registration is running.
                      onPressed: _isLoading ? null : _handleRegister,

                      // Show a loading spinner while waiting for Firebase.
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,

                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          // Show the Register text when not loading.
                          : const Text('Register'),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ---------------------------------------------------
                  // Login Link
                  // ---------------------------------------------------
                  // Allows users who already have an account to
                  // return to the previous login screen.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,

                    children: [
                      const Text('Already have an account? '),

                      GestureDetector(
                        // Return to the previous screen when tapped.
                        onTap: () => Navigator.of(context).pop(),

                        child: const Text(
                          'Log In',

                          style: TextStyle(
                            color: AppColors.primaryTeal,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
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

/// Widget: _FieldLabel
/// -------------------------------------------------------------------
/// A reusable label displayed above each registration input field.
///
/// The label keeps the styling of all form field headings consistent.
class _FieldLabel extends StatelessWidget {
  // Text displayed as the field label.
  final String text;

  /// Creates a field label using the provided text.
  const _FieldLabel(this.text);

  /// Builds the field label.
  @override
  Widget build(BuildContext context) {
    return Padding(
      // Add a small gap below the label.
      padding: const EdgeInsets.only(bottom: 6),

      child: Text(
        text,

        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.black54,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
