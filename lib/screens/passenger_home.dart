import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  /// Creates the passenger landing page with the displayed account name.
  const PassengerHomeScreen({
    super.key,
    this.userName = 'User',
    this.userId,
    this.avatarImageUrl,
    this.onFindRide,
  });

  /// Name displayed in the passenger home header.
  final String userName;
  final String? userId;
  final String? avatarImageUrl;
  final VoidCallback? onFindRide;

  String? get _effectiveUserId =>
      userId ?? FirebaseAuth.instance.currentUser?.uid;

  Stream<QuerySnapshot<Map<String, dynamic>>> _recentRidesStream(String uid) =>
      FirebaseFirestore.instance
          .collection('ride_requests')
          .where('passengerId', isEqualTo: uid)
          .snapshots();

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

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
              _buildRecentRides(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final avatarUrl = avatarImageUrl;
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: RPColors.teal.withValues(alpha: 0.1),
          backgroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl),
          child: avatarUrl == null
              ? const Icon(Icons.person, color: RPColors.teal)
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '$_greeting, $userName',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: RPColors.textDark,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return InkWell(
      onTap:
          onFindRide ??
          () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Choose a pickup hub to book a ride.'),
            ),
          ),
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
              'Available drivers',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: RPColors.textDark,
              ),
            ),
            const _AvailableDriverCountIndicator(),
          ],
        ),
      ],
    );
  }

  Widget _buildRecentRides() {
    final uid = _effectiveUserId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent rides',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: RPColors.textDark,
          ),
        ),
        const SizedBox(height: 12),
        if (uid == null)
          const Text(
            'Sign in to see your recent rides.',
            style: TextStyle(color: RPColors.textGrey),
          )
        else
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _recentRidesStream(uid),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'Unable to load your recent rides.',
                  style: TextStyle(color: RPColors.danger),
                );
              }
              if (!snapshot.hasData) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(color: RPColors.teal),
                  ),
                );
              }
              final rides = [...snapshot.data!.docs]
                ..sort(
                  (a, b) =>
                      _createdAt(b.data()).compareTo(_createdAt(a.data())),
                );
              if (rides.isEmpty) {
                return const Text(
                  'Your recent rides will appear here.',
                  style: TextStyle(color: RPColors.textGrey),
                );
              }
              final recentRides = rides.take(2).toList();
              return Column(
                children: [
                  for (var index = 0; index < recentRides.length; index++) ...[
                    _buildRecentTile(
                      icon: Icons.location_on_outlined,
                      title:
                          recentRides[index]
                              .data()['dropoffAddress']
                              ?.toString() ??
                          'Ride destination',
                      subtitle:
                          'From ${recentRides[index].data()['pickupName']?.toString() ?? 'Pickup hub'} · '
                          '${_statusLabel(recentRides[index].data()['status']?.toString())}',
                    ),
                    if (index < recentRides.length - 1)
                      const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
      ],
    );
  }

  DateTime _createdAt(Map<String, dynamic> data) {
    final value = data['createdAt'];
    return value is Timestamp
        ? value.toDate()
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _statusLabel(String? status) {
    if (status == null || status.isEmpty) return 'Status unavailable';
    return status
        .split('_')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
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
        ],
      ),
    );
  }
}

class _AvailableDriverCountIndicator extends StatefulWidget {
  const _AvailableDriverCountIndicator();

  @override
  State<_AvailableDriverCountIndicator> createState() =>
      _AvailableDriverCountIndicatorState();
}

class _AvailableDriverCountIndicatorState
    extends State<_AvailableDriverCountIndicator> {
  static const _refreshInterval = Duration(seconds: 30);

  Timer? _refreshTimer;
  int? _count;
  Object? _error;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCount());
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      unawaited(_refreshCount());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshCount() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    try {
      final response = await FirebaseFunctions.instanceFor(
        region: 'asia-southeast1',
      ).httpsCallable('getAvailableDriverCount').call();
      final data = Map<String, dynamic>.from(response.data as Map);
      final count = data['count'];
      if (count is! int || count < 0) {
        throw StateError('The available driver count was invalid.');
      }
      if (mounted) {
        setState(() {
          _count = count;
          _error = null;
        });
      }
    } catch (error) {
      debugPrint('Unable to load available driver count: $error');
      if (mounted) setState(() => _error = error);
    } finally {
      _isRefreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: RPColors.teal,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _error != null
            ? 'Unavailable'
            : _count == null
            ? 'Loading…'
            : '$_count online',
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}
