import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'passenger_home.dart' show RPColors;
import 'payment_methods_screen.dart';
import 'transaction_history_screen.dart';

/// Mock top-up page. UI only: no payment is made. Pops with the new
/// [WalletTransaction] when the user confirms, or null if they back out.
class AddMoneyScreen extends StatefulWidget {
  const AddMoneyScreen({super.key, required this.currentBalance});

  final double currentBalance;

  @override
  State<AddMoneyScreen> createState() => _AddMoneyScreenState();
}

class _AddMoneyScreenState extends State<AddMoneyScreen> {
  static const _quickAmounts = [10, 20, 50, 100];
  static const _minAmount = 5.0;
  static const _maxAmount = 500.0;

  final _amountController = TextEditingController();
  PaymentMethodOption _method = paymentMethodOptions.first;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  double? get _amount => double.tryParse(_amountController.text);

  String? get _amountError {
    final a = _amount;
    if (_amountController.text.isEmpty) return null;
    if (a == null) return 'Enter a valid amount';
    if (a < _minAmount) {
      return 'Minimum top up is RM ${_minAmount.toStringAsFixed(0)}';
    }
    if (a > _maxAmount) {
      return 'Maximum top up is RM ${_maxAmount.toStringAsFixed(0)}';
    }
    return null;
  }

  bool get _canSubmit =>
      !_processing && _amount != null && _amountError == null;

  void _setQuickAmount(int value) {
    _amountController.text = value.toString();
    _amountController.selection = TextSelection.collapsed(
      offset: _amountController.text.length,
    );
  }

  Future<void> _submit() async {
    final amount = _amount!;
    FocusScope.of(context).unfocus();
    setState(() => _processing = true);

    // Pretend to talk to the payment provider.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() => _processing = false);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check, size: 36, color: Colors.green.shade700),
            ),
            const SizedBox(height: 16),
            const Text(
              'Top up successful',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: RPColors.textDark,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'RM ${amount.toStringAsFixed(2)} added via ${_method.name}.\n'
              'New balance: RM ${(widget.currentBalance + amount).toStringAsFixed(2)}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: RPColors.textGrey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (!mounted) return;

    Navigator.of(context).pop(
      WalletTransaction(
        title: 'Top up',
        subtitle: _method.name,
        amount: amount,
        date: DateTime.now(),
        type: TransactionType.topUp,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(
        backgroundColor: RPColors.bg,
        foregroundColor: RPColors.teal,
        elevation: 0,
        title: const Text(
          'Add Money',
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
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                children: [
                  _buildAmountCard(),
                  const SizedBox(height: 24),
                  const Text(
                    'Pay with',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: RPColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final m in paymentMethodOptions) ...[
                    _buildMethodTile(m),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Current balance: RM ${widget.currentBalance.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 13, color: RPColors.textGrey),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
            ],
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: RPColors.teal,
            ),
            decoration: InputDecoration(
              prefixText: 'RM ',
              prefixStyle: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: RPColors.teal,
              ),
              hintText: '0.00',
              errorText: _amountError,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in _quickAmounts)
                ChoiceChip(
                  label: Text('RM $a'),
                  selected: _amount == a.toDouble(),
                  onSelected: (_) => _setQuickAmount(a),
                  selectedColor: RPColors.teal,
                  backgroundColor: RPColors.cardBg,
                  side: const BorderSide(color: RPColors.border),
                  showCheckmark: false,
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _amount == a.toDouble()
                        ? Colors.white
                        : RPColors.textDark,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMethodTile(PaymentMethodOption m) {
    final selected = m.id == _method.id;
    return InkWell(
      onTap: () => setState(() => _method = m),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: RPColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? RPColors.teal : RPColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            PaymentLogo(method: m, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                m.name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: RPColors.textDark,
                ),
              ),
            ),
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? RPColors.teal : RPColors.textGrey,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final amount = _amount;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        color: RPColors.cardBg,
        border: Border(top: BorderSide(color: RPColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton(
            onPressed: _canSubmit ? _submit : null,
            child: _processing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    _canSubmit
                        ? 'Top up RM ${amount!.toStringAsFixed(2)}'
                        : 'Top up',
                  ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Demo only. No real payment is made.',
            style: TextStyle(fontSize: 12, color: RPColors.textGrey),
          ),
        ],
      ),
    );
  }
}
