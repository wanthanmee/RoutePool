import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;
import 'rate_driver_screen.dart';

/// Watches a passenger's own requests, independently of the selected tab.
class RideReviewPrompt extends StatefulWidget {
  const RideReviewPrompt({super.key, required this.passengerId});

  final String passengerId;

  @override
  State<RideReviewPrompt> createState() => _RideReviewPromptState();
}

class _RideReviewPromptState extends State<RideReviewPrompt> {
  final Set<String> _handledRequestIds = {};
  final List<String> _pendingRequestIds = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  StreamSubscription<User?>? _authSubscription;
  bool _showingPrompt = false;

  @override
  void initState() {
    super.initState();

    final currentUser = FirebaseAuth.instance.currentUser;
    final authUid = currentUser?.uid;
    final passengerId = widget.passengerId;

    debugPrint('===== REVIEW LISTENER DEBUG =====');
    debugPrint('Authenticated UID: $authUid');
    debugPrint('Widget Passenger ID: $passengerId');
    debugPrint('IDs match: ${authUid == passengerId}');
    debugPrint('===============================');

    if (authUid == null || authUid != passengerId) {
      debugPrint(
        'REVIEW LISTENER: Not started because authentication '
        'is missing or passenger ID does not match.',
      );
      return;
    }

    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user?.uid == widget.passengerId) return;
      debugPrint(
        'REVIEW LISTENER: stopping because authenticated user changed '
        'from ${widget.passengerId} to ${user?.uid}.',
      );
      unawaited(_subscription?.cancel());
      _subscription = null;
      _pendingRequestIds.clear();
    });

    _subscription = FirebaseFirestore.instance
        .collection('ride_requests')
        .where('passengerId', isEqualTo: authUid)
        .snapshots()
        .listen(
          _handleRequests,
          onError: (Object error, StackTrace stackTrace) {
            final code = error is FirebaseException ? error.code : null;
            debugPrint(
              'REVIEW LISTENER FIRESTORE FAILURE: operation="list '
              'ride_requests where passengerId=$authUid", '
              'kind=${code == 'permission-denied' ? 'permission-denied' : 'stream-error'}, '
              'error=$error',
            );
            debugPrintStack(stackTrace: stackTrace);

            if (FirebaseAuth.instance.currentUser?.uid == widget.passengerId) {
              _showError('Unable to check for confirmed drop-offs: $error');
            }
          },
        );
  }

  bool _isEligible(String requestId, Map<String, dynamic> request) {
    final status = request['status'];

    final eligible =
        request['passengerId'] == widget.passengerId &&
        (status == 'drop_off_confirmed' || status == 'completed') &&
        request['reviewPromptEligibleAt'] != null;

    if (status == 'drop_off_confirmed' || status == 'completed') {
      debugPrint('===== REVIEW ELIGIBILITY =====');
      debugPrint('Request ID: $requestId');
      debugPrint('Status: $status');
      debugPrint('Eligible at: ${request['reviewPromptEligibleAt']}');
      debugPrint('Prompt state: ${request['reviewPromptState']}');
      debugPrint('Eligible: $eligible');
    }

    return eligible;
  }

  void _handleRequests(QuerySnapshot<Map<String, dynamic>> snapshot) {
    if (FirebaseAuth.instance.currentUser?.uid != widget.passengerId) return;
    for (final doc in snapshot.docs) {
      if (_isEligible(doc.id, doc.data()) && _handledRequestIds.add(doc.id)) {
        _pendingRequestIds.add(doc.id);
      }
    }

    if (_pendingRequestIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showNextPrompt());
      });
    }
  }

  Future<_PendingReview?> _claimPrompt(String requestId) async {
    final db = FirebaseFirestore.instance;
    final requestRef = db.collection('ride_requests').doc(requestId);
    final reviewRef = db.collection('reviews').doc(requestId);
    final claimId = UniqueKey().toString();
    var operation = 'read ride_requests/$requestId';

    try {
      return await db.runTransaction((transaction) async {
        operation = 'read ride_requests/$requestId';
        final requestSnapshot = await transaction.get(requestRef);
        final request = requestSnapshot.data();
        if (request == null || !_isEligible(requestId, request)) return null;
        debugPrint(
          'REVIEW CLAIM DATA: request=$requestId, '
          'passengerId=${request['passengerId']}, status=${request['status']}, '
          'eligibleAt=${request['reviewPromptEligibleAt']}, '
          'tripId=${request['groupId']}, driverId=${request['driverId']}.',
        );

        final currentState = request['reviewPromptState'];
        if (currentState is Map && currentState['status'] == 'shown') {
          return null;
        }
        if (currentState is Map &&
            currentState['status'] == 'showing' &&
            currentState['claimedAt'] is Timestamp &&
            DateTime.now().difference(
                  (currentState['claimedAt'] as Timestamp).toDate(),
                ) <
                const Duration(minutes: 2)) {
          return null;
        }

        operation = 'read reviews/$requestId for duplicate prevention';
        final reviewSnapshot = await transaction.get(reviewRef);
        if (reviewSnapshot.exists) return null;

        final tripId = (request['groupId'] ?? '').toString();
        final driverId = (request['driverId'] ?? '').toString();
        if (tripId.isEmpty) {
          throw StateError('The trip linked to this booking was not found.');
        }
        if (driverId.isEmpty || driverId == widget.passengerId) {
          throw StateError('An assigned driver was not found.');
        }

        operation =
            'update ride_requests/$requestId.reviewPromptState to showing';
        transaction.update(requestRef, {
          'reviewPromptState': {
            'status': 'showing',
            'claimId': claimId,
            'claimedAt': FieldValue.serverTimestamp(),
          },
        });

        return _PendingReview(
          requestId: requestId,
          tripId: tripId,
          driverId: driverId,
          claimId: claimId,
        );
      });
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'REVIEW PROMPT FIRESTORE FAILURE: operation="$operation", '
        'code=${error.code}, message=${error.message}',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _markPromptShown(_PendingReview review) async {
    final requestRef = FirebaseFirestore.instance
        .collection('ride_requests')
        .doc(review.requestId);
    var operation = 'read ride_requests/${review.requestId}';
    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        operation = 'read ride_requests/${review.requestId}';
        final snapshot = await transaction.get(requestRef);
        final request = snapshot.data();
        final state = request?['reviewPromptState'];
        if (request == null ||
            !_isEligible(review.requestId, request) ||
            state is! Map ||
            state['claimId'] != review.claimId) {
          throw StateError('The review prompt claim is no longer valid.');
        }
        operation =
            'update ride_requests/${review.requestId}.reviewPromptState to shown';
        transaction.update(requestRef, {
          'reviewPromptState': {
            'status': 'shown',
            'shownAt': FieldValue.serverTimestamp(),
          },
        });
      });
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'REVIEW PROMPT FIRESTORE FAILURE: operation="$operation", '
        'code=${error.code}, message=${error.message}',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _releasePromptClaim(_PendingReview review) async {
    final requestRef = FirebaseFirestore.instance
        .collection('ride_requests')
        .doc(review.requestId);
    var operation = 'read ride_requests/${review.requestId}';
    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        operation = 'read ride_requests/${review.requestId}';
        final snapshot = await transaction.get(requestRef);
        final state = snapshot.data()?['reviewPromptState'];
        if (state is Map && state['claimId'] == review.claimId) {
          operation =
              'update ride_requests/${review.requestId}.reviewPromptState to pending';
          transaction.update(requestRef, {
            'reviewPromptState': {
              'status': 'pending',
              'updatedAt': FieldValue.serverTimestamp(),
            },
          });
        }
      });
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'REVIEW CLAIM RELEASE FIRESTORE FAILURE: operation="$operation", '
        'code=${error.code}, message=${error.message}',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _showNextPrompt() async {
    if (!mounted ||
        FirebaseAuth.instance.currentUser?.uid != widget.passengerId ||
        _showingPrompt ||
        _pendingRequestIds.isEmpty) {
      return;
    }
    _showingPrompt = true;
    final requestId = _pendingRequestIds.removeAt(0);
    _PendingReview? review;
    var promptShown = false;

    try {
      review = await _claimPrompt(requestId);
      if (!mounted || review == null) return;

      final dialogResult = showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Ride completed!'),
          content: const Text(
            'You have reached your destination. How was your experience with your driver?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Maybe Later'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: RPColors.teal),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Rate Your Driver'),
            ),
          ],
        ),
      );

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      Object? markerError;
      try {
        await _markPromptShown(review);
        promptShown = true;
      } catch (error) {
        markerError = error;
      }

      final shouldReview = await dialogResult;
      if (!promptShown) {
        await _releasePromptClaim(review);
      }
      if (markerError != null) {
        throw StateError(
          'Unable to save that the prompt was shown: $markerError',
        );
      }
      if (!mounted || shouldReview != true) return;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RateDriverScreen(
            requestId: review!.requestId,
            tripId: review.tripId,
            driverId: review.driverId,
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('REVIEW PROMPT ERROR: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (review != null &&
          !promptShown &&
          FirebaseAuth.instance.currentUser?.uid == widget.passengerId) {
        try {
          await _releasePromptClaim(review);
        } catch (releaseError) {
          debugPrint('REVIEW CLAIM RELEASE ERROR: $releaseError');
        }
      }

      // Allow another Firestore update to retry a failed request.
      _handledRequestIds.remove(requestId);

      if (FirebaseAuth.instance.currentUser?.uid == widget.passengerId) {
        _showError('Unable to open driver review: $error');
      } else {
        debugPrint(
          'REVIEW PROMPT: suppressed error after authentication changed: '
          '$error',
        );
      }
    } finally {
      _showingPrompt = false;

      if (mounted && _pendingRequestIds.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showNextPrompt());
        });
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _PendingReview {
  const _PendingReview({
    required this.requestId,
    required this.tripId,
    required this.driverId,
    required this.claimId,
  });

  final String requestId;
  final String tripId;
  final String driverId;
  final String claimId;
}
