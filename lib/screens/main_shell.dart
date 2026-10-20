import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'app_user_profile.dart';
import 'driver_dashboard.dart';
import 'hub_screen.dart';
import 'passenger_home.dart';
import 'profile_screen.dart';
import 'rides_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.userProfile,
    this.initialIndex = 0,
  });

  /// The profile loaded at login. Used until the live data arrives and as a
  /// fallback if the connection drops.
  final AppUserProfile userProfile;
  final int initialIndex;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late int _index = widget.initialIndex;
  final Set<int> _visited = {};

  /// Last good profile, so a stream error never blanks the screens.
  late AppUserProfile _latest = widget.userProfile;

  /// Live copy of users/{uid}. Every edit (name, phone, photo...) shows up
  /// on all tabs without logging in again.
  late final Stream<AppUserProfile> _profileStream = FirebaseFirestore.instance
      .collection('users')
      .doc(widget.userProfile.uid)
      .snapshots()
      .where((doc) => doc.exists && doc.data() != null)
      .map((doc) => AppUserProfile.fromFirestore(doc.id, doc.data()!));

  @override
  void initState() {
    super.initState();
    _visited.add(_index);
  }

  Widget _buildPage(int i, AppUserProfile profile) {
    switch (i) {
      case 0:
        return profile.isDriver
            ? DriverDashboardScreen(driverName: profile.name)
            : PassengerHomeScreen(userName: profile.name);
      case 1:
        return RidesScreen(isDriver: profile.isDriver);
      case 2:
        return HubScreen(
          isDriver: profile.isDriver,
          orsApiKey: const String.fromEnvironment('ORS_API_KEY'),
        );
      case 3:
        return const _Placeholder('Wallet');
      default:
        return ProfileScreen(userProfile: profile);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUserProfile>(
      stream: _profileStream,
      initialData: widget.userProfile,
      builder: (context, snapshot) {
        final profile = snapshot.data ?? _latest;
        _latest = profile;
        final isDriver = profile.isDriver;

        return Scaffold(
          body: IndexedStack(
            index: _index,
            children: [
              for (int i = 0; i < 5; i++)
                _visited.contains(i)
                    ? _buildPage(i, profile)
                    : const SizedBox.shrink(),
            ],
          ),
          bottomNavigationBar: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.white,
              indicatorColor: RPColors.teal.withValues(alpha: 0.12),
              iconTheme: WidgetStateProperty.resolveWith(
                (s) => IconThemeData(
                  color: s.contains(WidgetState.selected)
                      ? RPColors.teal
                      : RPColors.textGrey,
                ),
              ),
              labelTextStyle: WidgetStateProperty.resolveWith(
                (s) => TextStyle(
                  fontSize: 11,
                  color: s.contains(WidgetState.selected)
                      ? RPColors.teal
                      : RPColors.textGrey,
                ),
              ),
            ),
            child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() {
                _index = i;
                _visited.add(i);
              }),
              destinations: [
                NavigationDestination(
                  icon: Icon(
                    isDriver ? Icons.dashboard_outlined : Icons.home_outlined,
                  ),
                  selectedIcon: Icon(
                    isDriver ? Icons.dashboard : Icons.home_filled,
                  ),
                  label: isDriver ? 'Dashboard' : 'Home',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.directions_car_filled_outlined),
                  selectedIcon: Icon(Icons.directions_car_filled),
                  label: 'Rides',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.hub_outlined),
                  selectedIcon: Icon(Icons.hub),
                  label: 'Hubs',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  selectedIcon: Icon(Icons.account_balance_wallet),
                  label: 'Wallet',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(child: Text(title)),
  );
}
