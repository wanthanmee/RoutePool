import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;
import 'ride_history_detail_screen.dart';

enum _DateFilter { all, thisMonth, lastMonth, custom }

class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key, required this.isDriver});

  final bool isDriver;

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  _DateFilter _filter = _DateFilter.all;
  DateTimeRange? _customRange;
  bool _newestFirst = true;

  Future<void> _chooseCustomRange() async {
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 2, 12, 31),
      initialDateRange: _customRange,
    );
    if (!mounted || selected == null) return;
    setState(() {
      _customRange = selected;
      _filter = _DateFilter.custom;
    });
  }

  bool _matchesDate(DateTime date) {
    if (_filter == _DateFilter.all) return true;
    if (date.millisecondsSinceEpoch == 0) return false;
    final now = DateTime.now();
    switch (_filter) {
      case _DateFilter.all:
        return true;
      case _DateFilter.thisMonth:
        return date.year == now.year && date.month == now.month;
      case _DateFilter.lastMonth:
        final lastMonth = DateTime(now.year, now.month - 1);
        return date.year == lastMonth.year && date.month == lastMonth.month;
      case _DateFilter.custom:
        final range = _customRange;
        if (range == null) return true;
        final day = DateTime(date.year, date.month, date.day);
        final start = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
        final end = DateTime(range.end.year, range.end.month, range.end.day);
        return !day.isBefore(start) && !day.isAfter(end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Please sign in again.')));
    }

    final db = FirebaseFirestore.instance;
    final stream = widget.isDriver
        ? db.collection('trips').where('driverId', isEqualTo: uid).snapshots()
        : db
              .collection('ride_requests')
              .where('passengerId', isEqualTo: uid)
              .snapshots();

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(title: const Text('Ride History'), centerTitle: true),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('All', _DateFilter.all),
                      const SizedBox(width: 8),
                      _filterChip('This Month', _DateFilter.thisMonth),
                      const SizedBox(width: 8),
                      _filterChip('Last Month', _DateFilter.lastMonth),
                      const SizedBox(width: 8),
                      ActionChip(
                        avatar: const Icon(Icons.date_range, size: 17),
                        label: Text(
                          _filter == _DateFilter.custom && _customRange != null
                              ? '${_customRange!.start.day}/${_customRange!.start.month} - ${_customRange!.end.day}/${_customRange!.end.month}'
                              : 'Custom Range',
                        ),
                        backgroundColor: _filter == _DateFilter.custom
                            ? RPColors.teal.withValues(alpha: 0.12)
                            : null,
                        onPressed: _chooseCustomRange,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.sort, size: 18, color: RPColors.textGrey),
                    const SizedBox(width: 8),
                    const Text(
                      'Sort by',
                      style: TextStyle(color: RPColors.textGrey),
                    ),
                    const Spacer(),
                    DropdownButton<bool>(
                      value: _newestFirst,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: true,
                          child: Text('Newest First'),
                        ),
                        DropdownMenuItem(
                          value: false,
                          child: Text('Oldest First'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _newestFirst = value);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Unable to load ride history.'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final completedRides = snapshot.data!.docs.where((doc) {
                  final status = doc.data()['status'];
                  return widget.isDriver
                      ? status == 'completed'
                      : status == 'completed' || status == 'drop_off_confirmed';
                }).toList();

                final rides = completedRides.where((doc) {
                  return _matchesDate(_rideDate(doc.data()));
                }).toList();

                rides.sort((a, b) {
                  final comparison = _rideDate(a.data())
                      .compareTo(_rideDate(b.data()));
                  return _newestFirst ? -comparison : comparison;
                });

                if (rides.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        completedRides.isEmpty
                            ? 'No completed rides yet.'
                            : 'No completed rides in the selected date range.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rides.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final doc = rides[index];
                    final data = doc.data();
                    final pickup =
                        (data['pickupName'] ??
                                data['pickupAddress'] ??
                                'Pickup unavailable')
                            .toString();
                    final destination = widget.isDriver
                        ? 'Shared trip · ${data['totalPassengers'] ?? '?'} passenger(s)'
                        : (data['dropoffName'] ??
                                  data['dropoffAddress'] ??
                                  'Destination unavailable')
                              .toString();
                    final fare = widget.isDriver
                        ? data['totalFareSen']
                        : data['fareShareSen'];
                    final rideDate = _rideDate(data);

                    return Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => RideHistoryDetailScreen(
                                rideId: doc.id,
                                isDriver: widget.isDriver,
                              ),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.calendar_today_outlined,
                                    size: 13,
                                    color: RPColors.textGrey,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _formatDate(rideDate),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RPColors.textGrey,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '$pickup → $destination',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: RPColors.textDark,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _formatFare(fare),
                                    style: const TextStyle(
                                      color: RPColors.teal,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: RPColors.textGrey,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.account_circle,
                                    color: RPColors.teal,
                                    size: 19,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    widget.isDriver
                                        ? 'Driver trip'
                                        : 'Your ride',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RPColors.textGrey,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (!widget.isDriver) ...[
                                    _ReviewBadge(requestId: doc.id),
                                    const SizedBox(width: 8),
                                  ],
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFD8F7E4),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text(
                                      'COMPLETED',
                                      style: TextStyle(
                                        color: Color(0xFF23834B),
                                        fontSize: 10,
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
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, _DateFilter filter) {
    return ChoiceChip(
      label: Text(label),
      selected: _filter == filter,
      selectedColor: RPColors.teal.withValues(alpha: 0.16),
      onSelected: (_) => setState(() => _filter = filter),
    );
  }
}

class _ReviewBadge extends StatelessWidget {
  const _ReviewBadge({required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('reviews').doc(requestId).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const SizedBox.shrink();
        }
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }
        return snapshot.data!.exists
            ? _reviewedBadge()
            : const SizedBox.shrink();
      },
    );
  }

  Widget _reviewedBadge() {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, size: 14, color: Color(0xFF23834B)),
        SizedBox(width: 3),
        Text(
          'Reviewed',
          style: TextStyle(
            color: Color(0xFF23834B),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

DateTime _rideDate(Map<String, dynamic> data) {
  for (final key in [
    'droppedOffAt',
    'completedAt',
    'departureTime',
    'createdAt',
  ]) {
    final value = data[key];
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

String _formatDate(DateTime date) {
  if (date.millisecondsSinceEpoch == 0) return 'Date unavailable';
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  final suffix = date.hour < 12 ? 'AM' : 'PM';
  return '${date.day}/${date.month}/${date.year}, $hour:$minute $suffix';
}

String _formatFare(dynamic value) {
  if (value is! num) return 'Unavailable';
  return 'RM ${(value / 100).toStringAsFixed(2)}';
}
