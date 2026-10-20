import 'package:flutter/material.dart';

import 'dart:async';

import '../services/ride_request_service.dart';

import 'ride_matching_screen.dart';

class BookRideScreen extends StatefulWidget {
  final String pickupHubId;
  final String pickupName;
  final String pickupAddress;
  final double pickupLat;
  final double pickupLon;

  const BookRideScreen({
    super.key,
    required this.pickupHubId,
    required this.pickupName,
    required this.pickupAddress,
    required this.pickupLat,
    required this.pickupLon,
  });

  @override
  State<BookRideScreen> createState() => _BookRideScreenState();
}

class _BookRideScreenState extends State<BookRideScreen> {
  static const Color teal = Color(0xFF0F5C5F);
  //static const Color orange = Color(0xFFF5A623);

  final TextEditingController _dropoffController = TextEditingController();
  double? _selectedDropoffLat;
  double? _selectedDropoffLon;
  final RideRequestService _rideRequestService = RideRequestService();

  Timer? _suggestionDebounce;

  List<Map<String, dynamic>> _dropoffSuggestions = [];

  bool _isLoadingSuggestions = false;

  bool _isSubmitting = false;

  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();
  int _passengerCount = 1;

  @override
  void dispose() {
    _suggestionDebounce?.cancel();
    _dropoffController.dispose();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
    );

    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  Future<void> _chooseTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );

    if (time != null) {
      setState(() => _selectedTime = time);
    }
  }

  void _onDropoffChanged(String value) {
    _selectedDropoffLat = null;
    _selectedDropoffLon = null;

    _suggestionDebounce?.cancel();

    final query = value.trim();

    debugPrint('[Drop-off] User typed: "$query"');

    if (query.length < 3) {
      setState(() {
        _dropoffSuggestions = [];
        _isLoadingSuggestions = false;
      });
      debugPrint('[Drop-off] Query too short; minimum is 3 characters.');
      return;
    }

    setState(() => _isLoadingSuggestions = true);

    _suggestionDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        debugPrint('[Drop-off] Sending Photon request for: "$query"');

        final results = await _rideRequestService.searchDestinationSuggestions(
          query,
        );

        debugPrint('[Drop-off] Photon returned ${results.length} results.');

        if (!mounted || _dropoffController.text.trim() != query) {
          debugPrint('[Drop-off] Ignoring outdated search results.');
          return;
        }

        setState(() {
          _dropoffSuggestions = results;
          _isLoadingSuggestions = false;
        });

        if (results.isEmpty) {
          debugPrint('[Drop-off] No suggestions found.');
        } else {
          debugPrint('[Drop-off] First result: ${results.first['address']}');
        }
      } catch (e, stackTrace) {
        debugPrint('[Drop-off] ERROR: $e');
        debugPrint('[Drop-off] STACK TRACE: $stackTrace');

        if (!mounted) return;

        setState(() {
          _dropoffSuggestions = [];
          _isLoadingSuggestions = false;
        });
      }
    });
  }

  void _selectDropoffSuggestion(Map<String, dynamic> suggestion) {
    _suggestionDebounce?.cancel();

    _dropoffController.text = suggestion['address'] as String;

    _selectedDropoffLat = (suggestion['lat'] as num?)?.toDouble();
    _selectedDropoffLon = (suggestion['lon'] as num?)?.toDouble();

    setState(() {
      _dropoffSuggestions = [];
      _isLoadingSuggestions = false;
    });

    FocusScope.of(context).unfocus();

    debugPrint('[Booking] Selected destination: ${suggestion['address']}');
    debugPrint('[Booking] Latitude: $_selectedDropoffLat');
    debugPrint('[Booking] Longitude: $_selectedDropoffLon');
  }

  Future<void> _findRoutePool() async {
    debugPrint('[Booking] Button pressed');

    if (_dropoffController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your drop-off location.')),
      );
      return;
    }

    if (_isSubmitting) {
      debugPrint('[Booking] Already submitting; ignored');
      return;
    }

    // Construct the selected departure date and time.
    final departureDateTime = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    // Validate that departure is in the future.
    if (!departureDateTime.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a future departure date and time.'),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      debugPrint('[Booking] Calling createRideRequest');
      debugPrint('[Booking] Destination: ${_dropoffController.text.trim()}');
      debugPrint('[Booking] Departure: $departureDateTime');

      final requestId = await _rideRequestService.createRideRequest(
        pickupHubId: widget.pickupHubId,
        pickupName: widget.pickupName,
        pickupAddress: widget.pickupAddress,
        pickupLat: widget.pickupLat,
        pickupLon: widget.pickupLon,
        dropoffAddress: _dropoffController.text.trim(),
        dropoffLat: _selectedDropoffLat,
        dropoffLon: _selectedDropoffLon,
        departureDateTime: departureDateTime,
        passengerCount: _passengerCount,
      );

      debugPrint('[Booking] Request created: $requestId');

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RideMatchingScreen(requestId: requestId),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('[Booking] ERROR: $e');
      debugPrint('[Booking] STACK TRACE: $stackTrace');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateText =
        '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}';

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: teal,
        elevation: 0,
        title: const Text('Book a Ride'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PICK-UP LOCATION',
                  style: TextStyle(
                    fontSize: 12,
                    color: teal,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: ValueKey(widget.pickupHubId),
                  initialValue: widget.pickupName,
                  readOnly: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.location_on, color: teal),
                    filled: true,
                    fillColor: const Color(0xFFF1F3F4),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (widget.pickupAddress.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.pickupAddress,
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 20),
                const Text(
                  'DROP-OFF LOCATION',
                  style: TextStyle(
                    fontSize: 12,
                    color: teal,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                // Drop-off field with location suggestions.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _dropoffController,
                      onChanged: _onDropoffChanged,
                      decoration: InputDecoration(
                        hintText: 'Enter destination or address',
                        prefixIcon: const Icon(
                          Icons.location_on,
                          color: Colors.red,
                        ),
                        suffixIcon: _isLoadingSuggestions
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: teal,
                                  ),
                                ),
                              )
                            : null,
                        filled: true,
                        fillColor: const Color(0xFFF1F3F4),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    if (_dropoffSuggestions.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.black12),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: _dropoffSuggestions.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final suggestion = _dropoffSuggestions[index];

                            return Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                leading: const Icon(
                                  Icons.location_on_outlined,
                                  color: teal,
                                ),
                                title: Text(
                                  suggestion['address'] as String,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                onTap: () =>
                                    _selectDropoffSuggestion(suggestion),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 10),
                const Text(
                  'Pick-up is at designated bus hubs only. '
                  'Drop-off can be at your chosen address.',
                  style: TextStyle(color: teal, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: _detailTile(
                  icon: Icons.calendar_today,
                  title: 'Date',
                  value: dateText,
                  onTap: _chooseDate,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _detailTile(
                  icon: Icons.access_time,
                  title: 'Time',
                  value: _selectedTime.format(context),
                  onTap: _chooseTime,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.people_alt_outlined, color: teal, size: 28),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'No. of Passengers',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: _passengerCount > 1
                      ? () => setState(() => _passengerCount--)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                Text(
                  '$_passengerCount',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                IconButton(
                  onPressed: _passengerCount < 4
                      ? () => setState(() => _passengerCount++)
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: teal,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Estimated Fare', style: TextStyle(color: Colors.white70)),
                SizedBox(height: 6),
                Text(
                  'Calculating...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          SizedBox(
            height: 54,
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _findRoutePool,
              style: ElevatedButton.styleFrom(
                backgroundColor: teal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Find RoutePool  ›',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: teal, size: 22),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(color: Colors.black54, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
