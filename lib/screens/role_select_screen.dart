import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

import 'register_screen.dart';

import 'login_screen.dart';

/// Widget: RoleSelectScreen
/// -------------------------------------------------------------------
/// Allows users to select how they want to use RoutePool:
/// as a passenger or as a driver.
///
/// Users can select a role to proceed to the registration screen.
/// Existing users can also navigate to the login screen.
class RoleSelectScreen extends StatelessWidget {
  const RoleSelectScreen({super.key});

  /// Builds the layout of the role selection screen.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Set the background colour of the screen.
      backgroundColor: AppColors.offWhite,

      body: Column(
        // Align the main content to the left.
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          // -----------------------------------------------------------
          // Header Section
          // -----------------------------------------------------------
          // Displays the RoutePool logo, app name, and role selection
          // question at the top of the screen.
          Container(
            width: double.infinity,
            color: AppColors.primaryTeal,

            // Add spacing around the header content.
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 30),

            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                // Display the RoutePool logo and app name.
                Row(
                  children: [
                    // Display the RoutePool logo inside a circular background.
                    CircleAvatar(
                      backgroundColor: Colors.white,
                      radius: 16,
                      child: Image.asset(
                        'assets/images/routepool_icon_transparent.png',
                        width: 18,
                      ),
                    ),

                    // Add spacing between the logo and app name.
                    const SizedBox(width: 8),

                    // Display the application name.
                    const Text(
                      'RoutePool',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),

                // Add spacing before the heading.
                const SizedBox(height: 16),

                // Ask the user how they want to use RoutePool.
                const Text(
                  'How will you\nuse RoutePool?',
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
          // Role Selection Section
          // -----------------------------------------------------------
          // Contains the Passenger and Driver role cards.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),

              child: Column(
                children: [
                  // Passenger role card.
                  // When tapped, the user is taken to passenger registration.
                  _RoleCard(
                    icon: Icons.people_alt_outlined,
                    label: "I'm a Passenger",

                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const RegisterScreen(role: 'passenger'),
                        ),
                      );
                    },
                  ),

                  // Add spacing between the Passenger and Driver cards.
                  const SizedBox(height: 16),

                  // Driver role card.
                  // When tapped, the user is taken to driver registration.
                  _RoleCard(
                    icon: Icons.directions_car_outlined,
                    label: "I'm a Driver",

                    // Use amber to distinguish the Driver icon.
                    iconColor: AppColors.accentAmber,

                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(role: 'driver'),
                        ),
                      );
                    },
                  ),

                  // Push the login section towards the bottom of the screen.
                  const Spacer(),

                  // ---------------------------------------------------
                  // Login Section
                  // ---------------------------------------------------
                  // Provides an option for users who already have
                  // an account to navigate to the login screen.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,

                    children: [
                      const Text("Already have an account "),

                      // "Log In" acts as a clickable link.
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const LoginScreen(),
                            ),
                          );
                        },

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

                  // Add spacing below the login section.
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Widget: _RoleCard
/// -------------------------------------------------------------------
/// A reusable card used to represent a user role.
///
/// The card displays an icon and role label and uses the provided
/// onTap callback when the user taps the card.
class _RoleCard extends StatelessWidget {
  // Icon displayed on the role card.
  final IconData icon;

  // Text displayed next to the icon.
  final String label;

  // Function that runs when the card is tapped.
  final VoidCallback onTap;

  // Colour of the role icon.
  // Defaults to the primary RoutePool teal colour.
  final Color iconColor;

  /// Creates a role card with the required icon, label, and tap action.
  const _RoleCard({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor = AppColors.primaryTeal,
  });

  /// Builds the layout of the role card.
  @override
  Widget build(BuildContext context) {
    return InkWell(
      // Run the provided callback when the card is tapped.
      onTap: onTap,

      // Give the tap/ripple effect rounded corners.
      borderRadius: BorderRadius.circular(12),

      child: Container(
        width: double.infinity,

        // Add space around the card's contents.
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),

        // Style the appearance of the card.
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.gray),
        ),

        child: Row(
          children: [
            // Display the role icon.
            Icon(icon, color: iconColor, size: 26),

            // Add spacing between the icon and label.
            const SizedBox(width: 14),

            // Display the role name.
            Text(
              label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
