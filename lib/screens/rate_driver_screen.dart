import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;

/// A passenger may review their assigned driver once per completed booking.
class RateDriverScreen extends StatefulWidget {
  const RateDriverScreen({
    super.key,
    required this.requestId,
    this.tripId,
    this.driverId,
  });

  final String requestId;
  final String? tripId;
  final String? driverId;

  @override
  State<RateDriverScreen> createState() => _RateDriverScreenState();
}

class _RateDriverScreenState extends State<RateDriverScreen> {
  static const _tags = <String>[
    'Safe Driver',
    'Friendly',
    'Punctual',
    'Clean Car',
    'Smooth Navigation',
  ];

  final _commentController = TextEditingController();
  final _selectedTags = <String>{};
  int _rating = 0;
  bool _submitting = false;

  Future<Map<String, dynamic>?> _loadDriverProfile(
    String tripId,
    String driverId,
  ) async {
    final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
        .httpsCallable('getTripParticipantProfiles');

    final response = await callable.call(<String, dynamic>{'tripId': tripId});

    final data = Map<String, dynamic>.from(response.data as Map);
    final profiles = Map<String, dynamic>.from(data['profiles'] as Map);

    final driver = profiles[driverId];

    return driver is Map ? Map<String, dynamic>.from(driver) : null;
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please choose a star rating.')),
      );
      return;
    }
    if (_submitting) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please sign in again.')));
      return;
    }

    setState(() => _submitting = true);
    try {
      final db = FirebaseFirestore.instance;
      final requestRef = db.collection('ride_requests').doc(widget.requestId);
      final reviewRef = db.collection('reviews').doc(widget.requestId);
      final rating = _rating;
      final tags = _tags.where(_selectedTags.contains).toList();
      final comment = _commentController.text.trim();
      var operation = 'read ride_requests/${widget.requestId}';

      try {
        await db.runTransaction((transaction) async {
          operation = 'read ride_requests/${widget.requestId}';
          final requestSnapshot = await transaction.get(requestRef);
          final request = requestSnapshot.data();
          if (request == null || request['passengerId'] != user.uid) {
            throw StateError('This booking does not belong to your account.');
          }
          if (!{
            'drop_off_confirmed',
            'completed',
          }.contains(request['status'])) {
            throw StateError(
              'You can review after your drop-off is confirmed.',
            );
          }
          final tripId = (request['groupId'] ?? '').toString();
          final driverId = (request['driverId'] ?? '').toString();
          if (tripId.isEmpty) {
            throw StateError('The trip linked to this booking was not found.');
          }
          if (driverId.isEmpty || driverId == user.uid) {
            throw StateError('An assigned driver was not found.');
          }
          operation =
              'read reviews/${widget.requestId} for duplicate prevention';
          final existingReview = await transaction.get(reviewRef);

          if (existingReview.exists) {
            throw StateError('You have already reviewed this ride.');
          }
          operation = 'create reviews/${widget.requestId}';
          transaction.set(reviewRef, {
            'tripId': tripId,
            'requestId': widget.requestId,
            'driverId': driverId,
            'passengerId': user.uid,
            'rating': rating,
            'tags': tags,
            'comment': comment,
            'createdAt': FieldValue.serverTimestamp(),
          });
        });
      } on FirebaseException catch (error, stackTrace) {
        debugPrint(
          'DRIVER REVIEW FIRESTORE FAILURE: operation="$operation", '
          'code=${error.code}, message=${error.message}',
        );
        debugPrintStack(stackTrace: stackTrace);
        rethrow;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you! Your review was submitted.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to submit review: $error')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }
    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(title: const Text('Rate Your Driver')),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: FirebaseFirestore.instance
            .collection('ride_requests')
            .doc(widget.requestId)
            .get(),
        builder: (context, requestSnapshot) {
          if (requestSnapshot.hasError) {
            debugPrint(
              'DRIVER REVIEW FIRESTORE FAILURE: operation="read '
              'ride_requests/${widget.requestId}", '
              'error=${requestSnapshot.error}',
            );
            return const Center(child: Text('Unable to load this booking.'));
          }
          if (!requestSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final request = requestSnapshot.data!.data();
          if (request == null || request['passengerId'] != user.uid) {
            return const Center(child: Text('Booking unavailable.'));
          }
          if (!{
            'drop_off_confirmed',
            'completed',
          }.contains(request['status'])) {
            return const Center(
              child: Text('You can rate the driver after drop-off.'),
            );
          }
          final tripId = (request['groupId'] ?? '').toString();
          final driverId = (request['driverId'] ?? '').toString();
          if (tripId.isEmpty ||
              driverId.isEmpty ||
              driverId == user.uid ||
              (widget.tripId != null && widget.tripId != tripId) ||
              (widget.driverId != null && widget.driverId != driverId)) {
            return const Center(child: Text('Trip information unavailable.'));
          }
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('reviews')
                .doc(widget.requestId)
                .snapshots(),
            builder: (context, reviewSnapshot) {
              if (reviewSnapshot.hasError) {
                debugPrint(
                  'DRIVER REVIEW FIRESTORE FAILURE: operation="listen '
                  'reviews/${widget.requestId}", error=${reviewSnapshot.error}',
                );
                return const Center(
                  child: Text('Unable to check review status.'),
                );
              }
              if (!reviewSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (reviewSnapshot.data!.exists) {
                return _submittedReview(reviewSnapshot.data!.data()!);
              }
              return FutureBuilder<Map<String, dynamic>?>(
                future: _loadDriverProfile(tripId, driverId),
                builder: (context, profileSnapshot) {
                  if (profileSnapshot.hasError) {
                    debugPrint(
                      'DRIVER REVIEW PROFILE FAILURE: callable '
                      'getTripParticipantProfiles for trip=$tripId: '
                      '${profileSnapshot.error}',
                    );
                    return const Center(
                      child: Text('Unable to load driver profile.'),
                    );
                  }

                  if (profileSnapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final driver = profileSnapshot.data;
                  final driverName = (driver?['name'] ?? 'Your Driver')
                      .toString();
                  final photo = (driver?['profilePic'] ?? '').toString();
                  return _buildForm(driverName, photo);
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _submittedReview(Map<String, dynamic> review) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 64, color: RPColors.teal),
            const SizedBox(height: 16),
            const Text(
              'Review submitted',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('${review['rating']} / 5 stars'),
            const SizedBox(height: 12),
            Text(
              (review['comment'] ?? '').toString(),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(String driverName, String photoUrl) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: CircleAvatar(
                radius: 43,
                backgroundColor: RPColors.teal,
                child: CircleAvatar(
                  radius: 38,
                  backgroundColor: Colors.white,
                  backgroundImage: photoUrl.isNotEmpty
                      ? NetworkImage(photoUrl)
                      : null,
                  child: photoUrl.isEmpty
                      ? const Icon(Icons.person, color: RPColors.teal, size: 56)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              driverName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: RPColors.textDark,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (index) {
                final star = index + 1;
                return IconButton(
                  tooltip: '$star star${star == 1 ? '' : 's'}',
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _rating = star),
                  icon: Icon(
                    star <= _rating ? Icons.star : Icons.star_border,
                    size: 37,
                    color: star <= _rating
                        ? RPColors.orange
                        : RPColors.textGrey,
                  ),
                );
              }),
            ),
            Text(
              _rating == 0 ? 'Tap to rate' : '$_rating out of 5 stars',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: RPColors.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'What went well?',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: RPColors.textDark,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _tags.map((tag) {
                final selected = _selectedTags.contains(tag);
                return FilterChip(
                  label: Text(tag),
                  selected: selected,
                  selectedColor: RPColors.teal.withValues(alpha: 0.15),
                  checkmarkColor: RPColors.teal,
                  onSelected: _submitting
                      ? null
                      : (value) => setState(() {
                          if (value) {
                            _selectedTags.add(tag);
                          } else {
                            _selectedTags.remove(tag);
                          }
                        }),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            const Text(
              'Leave a comment (optional)',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: RPColors.textDark,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _commentController,
              maxLines: 4,
              maxLength: 500,
              enabled: !_submitting,
              decoration: InputDecoration(
                hintText: 'How was your experience with $driverName?',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: RPColors.teal,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Submit Review',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
