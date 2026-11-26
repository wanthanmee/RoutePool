import 'package:flutter/material.dart';

import 'add_money_screen.dart';
import 'passenger_home.dart' show RPColors;
import 'payment_methods_screen.dart';
import 'transaction_history_screen.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({
    super.key,
    this.balance,
    this.avatarImageUrl,
    this.onAddMoney,
    this.onTransactionHistory,
    this.onConnectPaymentMethod,
  });

  /// Wallet balance in RM. Leave null to use the total of
  /// [mockTransactions], so it always matches the transaction history.
  final double? balance;

  final String? avatarImageUrl;

  /// Optional overrides. Leave null to use the built-in pages.
  final VoidCallback? onAddMoney;
  final VoidCallback? onTransactionHistory;
  final VoidCallback? onConnectPaymentMethod;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  double get _balance => widget.balance ?? walletBalance(mockTransactions);

  Future<void> _openAddMoney() async {
    final topUp = await Navigator.of(context).push<WalletTransaction>(
      MaterialPageRoute(
        builder: (_) => AddMoneyScreen(currentBalance: _balance),
      ),
    );
    if (topUp == null || !mounted) return;

    // Newest first, so the history and the balance stay in step.
    setState(() => mockTransactions.insert(0, topUp));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.cardBg,
      appBar: AppBar(
        backgroundColor: RPColors.bg,
        elevation: 0,
        title: const Text(
          'Wallet',
          style: TextStyle(
            color: RPColors.teal,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBalanceCard(context),
              const SizedBox(height: 24),
              Row(
                children: [
                  _buildActionTile(
                    icon: Icons.event_outlined,
                    label: 'Transaction\nHistory',
                    onTap:
                        widget.onTransactionHistory ??
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const TransactionHistoryScreen(),
                          ),
                        ),
                  ),
                  const SizedBox(width: 12),
                  _buildActionTile(
                    icon: Icons.history,
                    label: 'Connect payment\nMethod',
                    onTap:
                        widget.onConnectPaymentMethod ??
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PaymentMethodsScreen(),
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
  }

  Widget _buildBalanceCard(BuildContext context) {
    final url = widget.avatarImageUrl;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 72,
            height: 72,
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: RPColors.teal,
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: CircleAvatar(
                backgroundColor: RPColors.teal,
                backgroundImage: url != null ? NetworkImage(url) : null,
                child: url == null
                    ? const Icon(Icons.person, color: Colors.white, size: 40)
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(
                'RM ${_balance.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: RPColors.teal,
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: widget.onAddMoney ?? _openAddMoney,
            style: TextButton.styleFrom(
              foregroundColor: RPColors.textDark,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text(
              '+ Add Money',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: RPColors.cardBg,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 140,
          height: 140,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: RPColors.bg,
                  shape: BoxShape.circle,
                  border: Border.all(color: RPColors.border),
                ),
                child: Icon(icon, size: 24, color: RPColors.teal),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: RPColors.textDark),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
