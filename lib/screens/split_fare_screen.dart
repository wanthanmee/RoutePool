import 'package:flutter/material.dart';

import 'form_widgets.dart' show rpAppBar;
import 'passenger_home.dart' show RPColors;
import 'ride_mock_data.dart';
import 'ride_widgets.dart';

/// Available fare allocation strategies in the split-fare screen.
enum _SplitMode { dynamic, equal, manual }

/// Shows each passenger's share of the current ride fare.
class SplitFareScreen extends StatefulWidget {
  const SplitFareScreen({super.key});

  @override
  State<SplitFareScreen> createState() => _SplitFareScreenState();
}

/// Calculates and displays passenger fares for the selected split mode.
class _SplitFareScreenState extends State<SplitFareScreen> {
  _SplitMode _mode = _SplitMode.dynamic;

  /// Returns the displayed fare share for the passenger at [i].
  double _amountFor(int i) {
    switch (_mode) {
      case _SplitMode.dynamic:
      case _SplitMode.manual: // TODO: make manual amounts editable
        return ridePassengers[i].amount;
      case _SplitMode.equal:
        final base =
            (rideTotalFare / ridePassengers.length * 100).floor() / 100;
        // Leftover cents go to the first passenger so the total adds up.
        final remainder = rideTotalFare - base * ridePassengers.length;
        return i == 0 ? base + remainder : base;
    }
  }

  /// Formats a fare amount with two decimal places and a currency symbol.
  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final modeLabel = switch (_mode) {
      _SplitMode.dynamic => 'Dynamic Split',
      _SplitMode.equal => 'Equal Split',
      _SplitMode.manual => 'Manual Split',
    };

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Split Your Fare'),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ModeTabs(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
            const SizedBox(height: 16),
            const RPSectionLabel('PASSENGERS'),
            const SizedBox(height: 8),
            for (int i = 0; i < ridePassengers.length; i++) ...[
              _PassengerFareTile(
                passenger: ridePassengers[i],
                amount: _money(_amountFor(i)),
                highlight: i == 0,
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            RPCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const RPSectionLabel('TOTAL RIDE FARE'),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _money(rideTotalFare),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: RPColors.textDark,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: rpTealTint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          modeLabel,
                          style: const TextStyle(
                            fontSize: 10,
                            color: RPColors.teal,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24, color: RPColors.border),
                  RPFareRow('Your share', _money(_amountFor(0))),
                  const SizedBox(height: 6),
                  RPFareRow('Sarah M. (Shared)', _money(_amountFor(1))),
                  const SizedBox(height: 6),
                  RPFareRow('James L. (Shared)', _money(_amountFor(2))),
                ],
              ),
            ),
            const Spacer(),
            RPAccentButton(
              label: 'Confirm and Pay',
              icon: Icons.arrow_forward,
              // TODO: hook into the payment / wallet flow.
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lets the user choose the fare allocation strategy.
class _ModeTabs extends StatelessWidget {
  const _ModeTabs({required this.mode, required this.onChanged});

  final _SplitMode mode;
  final ValueChanged<_SplitMode> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: RPColors.cardBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: RPColors.border),
    ),
    child: Row(
      children: [
        for (final m in _SplitMode.values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(m),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: mode == m ? RPColors.teal : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  m.name[0].toUpperCase() + m.name.substring(1),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: mode == m ? Colors.white : RPColors.textGrey,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Shows one passenger and their calculated fare share.
class _PassengerFareTile extends StatelessWidget {
  const _PassengerFareTile({
    required this.passenger,
    required this.amount,
    required this.highlight,
  });

  final RidePassenger passenger;
  final String amount;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: highlight ? rpTealTint : RPColors.cardBg,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: highlight
            ? RPColors.teal.withValues(alpha: 0.3)
            : RPColors.border,
      ),
    ),
    child: Row(
      children: [
        const RPAvatar(size: 38),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    passenger.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!highlight) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: rpTealTint,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'SHARED ROUTE',
                        style: TextStyle(
                          fontSize: 7,
                          color: RPColors.teal,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                passenger.route,
                style: const TextStyle(fontSize: 10, color: RPColors.textGrey),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              amount,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: RPColors.teal,
              ),
            ),
            Text(
              passenger.status,
              style: const TextStyle(fontSize: 10, color: RPColors.textGrey),
            ),
          ],
        ),
      ],
    ),
  );
}
