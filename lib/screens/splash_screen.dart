import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/app_theme.dart';
import 'role_select_screen.dart';
import 'login_screen.dart';
import 'verification_screen.dart';
import 'rejected_screen.dart';
import 'app_user_profile.dart';
import 'ic_upload_screen.dart';
import 'main_shell.dart';
import 'license_upload_screen.dart';

/// Widget: SplashScreen
/// -------------------------------------------------------------------
/// Displays the RoutePool logo and app name when the application starts.
///
/// While the splash screen is displayed, the app checks whether the user
/// is logged in and checks their verification status in Firestore.
///
/// The user is then redirected to the appropriate screen based on their
/// authentication and verification status.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// Controls the behaviour and logic of the SplashScreen.
/// This class handles checking the user's login status, retrieving their
/// verification status from Firestore, and navigating to the correct screen.
class _SplashScreenState extends State<SplashScreen> {
  /// Runs once when the SplashScreen is first created.
  /// Starts the process of checking the user's authentication and
  /// verification status.
  @override
  void initState() {
    super.initState();

    _decideNextScreen();
  }

  /// Checks the user's authentication and verification status
  /// to determine which screen should be displayed next.
  Future<void> _decideNextScreen() async {
    // Keep the splash screen visible for at least 2 seconds.
    final minDelay = Future.delayed(const Duration(seconds: 2));

    // Firebase is initialized by main() in the running app. Widget tests can
    // render the app without initializing Firebase, so treat that as signed
    // out and show the normal entry screen.
    final user = Firebase.apps.isEmpty
        ? null
        : FirebaseAuth.instance.currentUser;

    // This variable will store the screen that the user should see next.
    Widget nextScreen;

    // If there is no logged-in user, send them to the role selection screen.
    if (user == null) {
      nextScreen = const RoleSelectScreen();
    } else {
      // A user is logged in, so retrieve their profile from Firestore.
      try {
        // Find the user's document inside the "users" collection.
        // The document ID is the user's Firebase UID.
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();

        // Check whether the user's Firestore profile exists.
        if (!doc.exists) {
          // The Firebase account exists, but there is no matching Firestore profile.
          await FirebaseAuth.instance.signOut();

          nextScreen = const RoleSelectScreen();
        } else {
          // Get the user's information from the Firestore document.
          final data = doc.data() as Map<String, dynamic>;

          // Get the user's verification status.
          // Possible values include "approved", "pending", or "rejected".
          final status = data['verificationStatus'];

          // If the user's verification is approved, go to the login screen
          if (status == 'approved') {
            final role = (data['role'] as String?)?.toLowerCase();

            if (role == 'passenger' || role == 'driver') {
              final profile = AppUserProfile.fromFirestore(user.uid, data);
              nextScreen = MainShell(userProfile: profile);
            } else {
              // Unknown role: fall back to login, same as before.
              nextScreen = const LoginScreen();
            }
          }
          // If verification is pending, check whether the IC/passport
          // has actually been uploaded before showing the verification screen.
          else if (status == 'pending') {
            final role = (data['role'] as String?)?.toLowerCase();

            final icPassport = (data['icPassport'] as String?)?.trim();
            final licenseUrl = (data['licenseUrl'] as String?)?.trim();

            // First, make sure the user has uploaded their IC/passport.
            if (icPassport == null || icPassport.isEmpty) {
              if (role == 'passenger' || role == 'driver') {
                nextScreen = IcUploadScreen(role: role!);
              } else {
                nextScreen = const LoginScreen();
              }
            }
            // Passengers only need the IC/passport for this verification flow.
            else if (role == 'passenger') {
              nextScreen = const VerificationScreen();
            }
            // Drivers must upload both their IC/passport and driving license.
            else if (role == 'driver') {
              if (licenseUrl == null || licenseUrl.isEmpty) {
                nextScreen = const LicenseUploadScreen();
              } else {
                nextScreen = const VerificationScreen();
              }
            } else {
              nextScreen = const LoginScreen();
            }
          }
          // If verification was rejected, show the rejection screen
          else if (status == 'rejected') {
            nextScreen = RejectedScreen(
              reason: data['rejectionReason'] as String?,
              role: data['role'] as String?,
              documentSubmissionAttempts:
                  (data['documentSubmissionAttempts'] as num?)?.toInt() ?? 0,
            );
          }
          // If the verification status is missing or unexpected, send the user to the login screen.
          else {
            nextScreen = const LoginScreen();
          }
        }
      } catch (e) {
        // A deleted account can briefly produce a Firestore error while Auth
        // is refreshing. Start a fresh application instead of reopening login.
        await FirebaseAuth.instance.signOut();
        nextScreen = const RoleSelectScreen();
      }
    }

    // Wait until the 2-second minimum splash screen duration has finished.
    await minDelay;

    // Check that the SplashScreen is still active before navigating.
    // If it has already been removed, stop the function.
    if (!mounted) return;

    // Replace the SplashScreen with the selected next screen.
    // pushReplacement prevents the user from pressing the Back button
    // and returning to the splash screen.
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => nextScreen));
  }

  /// Builds the visual layout of the SplashScreen.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Set the background colour using the app's custom theme.
      backgroundColor: AppColors.primaryTeal,

      body: Center(
        // Arrange the logo and text vertically.
        child: Column(
          // Place the entire column in the centre of the screen.
          mainAxisAlignment: MainAxisAlignment.center,

          children: [
            // Display the RoutePool logo from the assets folder.
            Image.asset(
              'assets/images/routepool_icon_transparent.png',
              width: 120,
            ),

            // Add vertical spacing between the logo and app name.
            const SizedBox(height: 20),

            // Display the application name.
            const Text(
              'RoutePool',

              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),

            // Add a small gap between the app name and tagline.
            const SizedBox(height: 4),

            // Display the application tagline.
            const Text(
              'Your Ride. Your Route. Penang',

              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
