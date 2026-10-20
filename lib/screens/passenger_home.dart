import 'package:flutter/material.dart';

/// RoutePool brand colors used across the passenger flow.
class RPColors {
  static const teal = Color(0xFF0F5C5F);
  static const tealDark = Color(0xFF0A4547);
  static const tealLight = Color(0xFF14666B);
  static const orange = Color(0xFFF5A623);
  static const bg = Color(0xFFF6F7F8);
  static const cardBg = Color(0xFFFFFFFF);
  static const textDark = Color(0xFF1C2B2C);
  static const textGrey = Color(0xFF8A9494);
  static const border = Color(0xFFE7EAEA);
  static const danger = Color(0xFFD64545);
}

class PassengerHomeScreen extends StatelessWidget {
  const PassengerHomeScreen({super.key, this.userName = 'Alessandra'});

  final String userName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildSearchBar(context),
              const SizedBox(height: 16),
              _buildRideHistoryChip(context),
              const SizedBox(height: 24),
              _buildAroundPenang(context),
              const SizedBox(height: 24),
              const Text(
                'Recent',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: RPColors.textDark,
                ),
              ),
              const SizedBox(height: 12),
              _buildRecentTile(
                icon: Icons.work_outline,
                title: 'Work',
                subtitle: 'Gurney Tower, Persiaran Gurney',
              ),
              const SizedBox(height: 10),
              _buildRecentTile(
                icon: Icons.home_outlined,
                title: 'Home',
                subtitle: 'Bayan Lepas, 11900 Penang',
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: RPColors.teal.withValues(alpha: 0.1),
          child: const Icon(Icons.person, color: RPColors.teal),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Good Morning, $userName',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: RPColors.textDark,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: RPColors.cardBg,
            shape: BoxShape.circle,
            border: Border.all(color: RPColors.border),
          ),
          child: const Icon(Icons.notifications_none, color: RPColors.textDark),
        ),
      ],
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).pushNamed('/book-ride'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: RPColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RPColors.border),
        ),
        child: const Row(
          children: [
            Icon(Icons.search, color: RPColors.textGrey),
            SizedBox(width: 10),
            Text(
              'Where are you going in Penang?',
              style: TextStyle(color: RPColors.textGrey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRideHistoryChip(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).pushNamed('/ride-history'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: RPColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RPColors.border),
        ),
        child: const Column(
          children: [
            Icon(Icons.history, color: RPColors.teal),
            SizedBox(height: 6),
            Text(
              'Ride\nHistory',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: RPColors.textDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAroundPenang(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Around Penang',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: RPColors.textDark,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: RPColors.teal,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                '12 drivers nearby',
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 160,
            width: double.infinity,
            color: RPColors.teal.withValues(alpha: 0.08),
            child: Stack(
              children: const [
                Center(
                  child: Icon(
                    Icons.map_outlined,
                    size: 48,
                    color: RPColors.teal,
                  ),
                ),
                Positioned(
                  left: 40,
                  top: 40,
                  child: Icon(
                    Icons.location_on,
                    color: RPColors.teal,
                    size: 28,
                  ),
                ),
                Positioned(
                  right: 60,
                  bottom: 30,
                  child: Icon(
                    Icons.location_on,
                    color: RPColors.teal,
                    size: 28,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentTile({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: RPColors.teal.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: RPColors.teal, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: RPColors.textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: RPColors.textGrey,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: RPColors.textGrey),
        ],
      ),
    );
  }
}
