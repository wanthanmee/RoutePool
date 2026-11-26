import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;

enum TransactionType { ridePayment, topUp, refund, splitFare, earning }

class WalletTransaction {
  const WalletTransaction({
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.date,
    required this.type,
  });

  final String title;
  final String subtitle;

  /// Positive for money in, negative for money out (RM).
  final double amount;
  final DateTime date;
  final TransactionType type;

  bool get isCredit => amount >= 0;
}

/// Mock data until the wallet is backed by Firestore. Newest first; the
/// wallet starts at RM 0.00, so these add up to the balance on the Wallet
/// page (running balance after each entry noted on the right).
final List<WalletTransaction> mockTransactions = [
  WalletTransaction(
    title: 'Ride to KL Sentral',
    subtitle: 'Hub: Bangsar LRT',
    amount: -6.35, // 20.00
    date: DateTime(2026, 10, 22, 8, 15),
    type: TransactionType.ridePayment,
  ),
  WalletTransaction(
    title: 'Top up',
    subtitle: 'Touch \'n Go eWallet',
    amount: 5.00, // 26.35
    date: DateTime(2026, 10, 21, 19, 42),
    type: TransactionType.topUp,
  ),
  WalletTransaction(
    title: 'Split fare received',
    subtitle: 'From Aisyah',
    amount: 3.25, // 21.35
    date: DateTime(2026, 10, 21, 18, 5),
    type: TransactionType.splitFare,
  ),
  WalletTransaction(
    title: 'Ride to Mid Valley',
    subtitle: 'Hub: Abdullah Hukum',
    amount: -4.80, // 18.10
    date: DateTime(2026, 10, 20, 17, 30),
    type: TransactionType.ridePayment,
  ),
  WalletTransaction(
    title: 'Cancelled ride refund',
    subtitle: 'Ride #RP10482',
    amount: 5.20, // 22.90
    date: DateTime(2026, 10, 19, 9, 12),
    type: TransactionType.refund,
  ),
  WalletTransaction(
    title: 'Ride booked',
    subtitle: 'Ride #RP10482',
    amount: -5.20, // 17.70
    date: DateTime(2026, 10, 19, 8, 40),
    type: TransactionType.ridePayment,
  ),
  WalletTransaction(
    title: 'Ride to Sunway Pyramid',
    subtitle: 'Hub: SS15 BRT',
    amount: -7.10, // 22.90
    date: DateTime(2026, 10, 18, 12, 48),
    type: TransactionType.ridePayment,
  ),
  WalletTransaction(
    title: 'Top up',
    subtitle: 'Online Banking (Maybank)',
    amount: 30.00, // 30.00
    date: DateTime(2026, 10, 15, 21, 3),
    type: TransactionType.topUp,
  ),
];

/// Wallet balance implied by [transactions], starting from RM 0.00.
double walletBalance(List<WalletTransaction> transactions) =>
    transactions.fold(0.0, (sum, t) => sum + t.amount);

class TransactionHistoryScreen extends StatefulWidget {
  const TransactionHistoryScreen({super.key, this.transactions});

  /// Leave null to show [mockTransactions].
  final List<WalletTransaction>? transactions;

  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen> {
  static const _filters = ['All', 'Money in', 'Money out'];
  String _filter = 'All';

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  List<WalletTransaction> get _all => widget.transactions ?? mockTransactions;

  List<WalletTransaction> get _visible {
    switch (_filter) {
      case 'Money in':
        return _all.where((t) => t.isCredit).toList();
      case 'Money out':
        return _all.where((t) => !t.isCredit).toList();
      default:
        return _all;
    }
  }

  /// Wallet balance right after each transaction, worked out oldest-first
  /// over the full list so it stays correct when a filter is applied.
  Map<WalletTransaction, double> get _balanceAfter {
    final result = <WalletTransaction, double>{};
    var running = 0.0;
    for (final t in _all.reversed) {
      running += t.amount;
      result[t] = running;
    }
    return result;
  }

  String _dateLabel(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  String _timeLabel(DateTime d) {
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final items = _visible;
    final balanceAfter = _balanceAfter;

    // Group by day, keeping the list order (newest first).
    final groups = <String, List<WalletTransaction>>{};
    for (final t in items) {
      groups.putIfAbsent(_dateLabel(t.date), () => []).add(t);
    }

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(
        backgroundColor: RPColors.bg,
        foregroundColor: RPColors.teal,
        elevation: 0,
        title: const Text(
          'Transaction History',
          style: TextStyle(
            color: RPColors.teal,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSummary(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                children: [
                  for (final f in _filters) ...[
                    ChoiceChip(
                      label: Text(f),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                      selectedColor: RPColors.teal,
                      backgroundColor: RPColors.cardBg,
                      side: const BorderSide(color: RPColors.border),
                      showCheckmark: false,
                      labelStyle: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _filter == f ? Colors.white : RPColors.textDark,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text(
                        'No transactions yet',
                        style: TextStyle(color: RPColors.textGrey),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      children: [
                        for (final entry in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 8),
                            child: Text(
                              entry.key,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: RPColors.textGrey,
                              ),
                            ),
                          ),
                          for (final t in entry.value)
                            _buildTile(t, balanceAfter[t]!),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Money in - money out = current balance, matching the Wallet page.
  Widget _buildSummary() {
    final moneyIn = _all
        .where((t) => t.isCredit)
        .fold(0.0, (sum, t) => sum + t.amount);
    final moneyOut = _all
        .where((t) => !t.isCredit)
        .fold(0.0, (sum, t) => sum - t.amount);

    Widget column(String label, String value, Color color) => Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: RPColors.textGrey),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Row(
        children: [
          column(
            'Money in',
            '+ RM ${moneyIn.toStringAsFixed(2)}',
            Colors.green.shade700,
          ),
          column(
            'Money out',
            '- RM ${moneyOut.toStringAsFixed(2)}',
            RPColors.danger,
          ),
          column(
            'Balance',
            'RM ${walletBalance(_all).toStringAsFixed(2)}',
            RPColors.teal,
          ),
        ],
      ),
    );
  }

  Widget _buildTile(WalletTransaction t, double balanceAfter) {
    final (icon, color) = switch (t.type) {
      TransactionType.ridePayment => (Icons.directions_car, RPColors.teal),
      TransactionType.topUp => (Icons.add_card, Colors.green),
      TransactionType.refund => (Icons.replay, RPColors.orange),
      TransactionType.splitFare => (Icons.call_split, Colors.indigo),
      TransactionType.earning => (Icons.payments_outlined, Colors.green),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: RPColors.textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${t.subtitle} · ${_timeLabel(t.date)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: RPColors.textGrey,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${t.isCredit ? '+' : '-'} RM ${t.amount.abs().toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: t.isCredit ? Colors.green.shade700 : RPColors.danger,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Bal RM ${balanceAfter.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 11, color: RPColors.textGrey),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
