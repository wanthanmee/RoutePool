import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;

/// What the "add details" sheet asks for.
enum PaymentMethodKind { bank, card, eWallet, googlePay }

class PaymentMethodOption {
  const PaymentMethodOption({
    required this.id,
    required this.name,
    required this.description,
    required this.kind,
    required this.logoText,
    required this.logoColor,
    this.logoTextColor = Colors.white,
    this.logoIcon,
  });

  final String id;
  final String name;
  final String description;
  final PaymentMethodKind kind;

  /// Mock logo: a coloured tile with short text (or an icon).
  final String logoText;
  final Color logoColor;
  final Color logoTextColor;
  final IconData? logoIcon;
}

const List<PaymentMethodOption> paymentMethodOptions = [
  PaymentMethodOption(
    id: 'fpx',
    name: 'Online Banking (FPX)',
    description: 'Maybank, CIMB, Public Bank and more',
    kind: PaymentMethodKind.bank,
    logoText: 'FPX',
    logoColor: Color(0xFF1B3A6B),
    logoIcon: Icons.account_balance,
  ),
  PaymentMethodOption(
    id: 'card',
    name: 'Credit / Debit Card',
    description: 'Visa, Mastercard, AMEX',
    kind: PaymentMethodKind.card,
    logoText: 'CARD',
    logoColor: Color(0xFF2D2D2D),
    logoIcon: Icons.credit_card,
  ),
  PaymentMethodOption(
    id: 'tng',
    name: 'Touch \'n Go eWallet',
    description: 'Link with your TNG phone number',
    kind: PaymentMethodKind.eWallet,
    logoText: 'TNG',
    logoColor: Color(0xFF005ABB),
  ),
  PaymentMethodOption(
    id: 'googlepay',
    name: 'Google Pay',
    description: 'Pay with your Google account',
    kind: PaymentMethodKind.googlePay,
    logoText: 'G Pay',
    logoColor: Colors.white,
    logoTextColor: Color(0xFF3C4043),
  ),
  PaymentMethodOption(
    id: 'shopeepay',
    name: 'ShopeePay',
    description: 'Link with your Shopee phone number',
    kind: PaymentMethodKind.eWallet,
    logoText: 'S Pay',
    logoColor: Color(0xFFEE4D2D),
  ),
  PaymentMethodOption(
    id: 'grabpay',
    name: 'GrabPay',
    description: 'Link with your Grab phone number',
    kind: PaymentMethodKind.eWallet,
    logoText: 'Grab',
    logoColor: Color(0xFF00B14F),
  ),
  PaymentMethodOption(
    id: 'boost',
    name: 'Boost',
    description: 'Link with your Boost phone number',
    kind: PaymentMethodKind.eWallet,
    logoText: 'Boost',
    logoColor: Color(0xFFE4002B),
  ),
];

class PaymentMethodsScreen extends StatefulWidget {
  const PaymentMethodsScreen({super.key});

  @override
  State<PaymentMethodsScreen> createState() => _PaymentMethodsScreenState();
}

class _PaymentMethodsScreenState extends State<PaymentMethodsScreen> {
  /// Method id -> masked detail shown on the tile, e.g. "•••• 4242".
  /// UI only: nothing is saved or sent anywhere.
  final Map<String, String> _connected = {};

  Future<void> _openMethod(PaymentMethodOption method) async {
    if (_connected.containsKey(method.id)) {
      final remove = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Remove ${method.name}?'),
          content: const Text('You can connect it again at any time.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                'Remove',
                style: TextStyle(color: RPColors.danger),
              ),
            ),
          ],
        ),
      );
      if (remove == true) setState(() => _connected.remove(method.id));
      return;
    }

    final detail = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RPColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PaymentDetailsSheet(method: method),
    );
    if (detail == null || !mounted) return;

    setState(() => _connected[method.id] = detail);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${method.name} connected')));
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
          'Payment Methods',
          style: TextStyle(
            color: RPColors.teal,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          children: [
            const Text(
              'Choose a payment method to connect to your RoutePool wallet.',
              style: TextStyle(fontSize: 13, color: RPColors.textGrey),
            ),
            const SizedBox(height: 16),
            for (final m in paymentMethodOptions) ...[
              _buildTile(m),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTile(PaymentMethodOption m) {
    final detail = _connected[m.id];
    return InkWell(
      onTap: () => _openMethod(m),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: RPColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: detail != null ? RPColors.teal : RPColors.border,
          ),
        ),
        child: Row(
          children: [
            PaymentLogo(method: m),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: RPColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail ?? m.description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: RPColors.textGrey,
                    ),
                  ),
                ],
              ),
            ),
            if (detail != null)
              const Icon(Icons.check_circle, color: RPColors.teal)
            else
              const Icon(Icons.chevron_right, color: RPColors.textGrey),
          ],
        ),
      ),
    );
  }
}

class PaymentLogo extends StatelessWidget {
  const PaymentLogo({super.key, required this.method, this.size = 48});

  final PaymentMethodOption method;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: method.logoColor,
        borderRadius: BorderRadius.circular(12),
        border: method.logoColor == Colors.white
            ? Border.all(color: RPColors.border)
            : null,
      ),
      child: method.logoIcon != null
          ? Icon(method.logoIcon, color: method.logoTextColor, size: size * 0.5)
          : Padding(
              padding: const EdgeInsets.all(4),
              child: FittedBox(
                child: Text(
                  method.logoText,
                  style: TextStyle(
                    color: method.logoTextColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
    );
  }
}

/// Mock form. Pops with a masked summary of what was entered.
class _PaymentDetailsSheet extends StatefulWidget {
  const _PaymentDetailsSheet({required this.method});

  final PaymentMethodOption method;

  @override
  State<_PaymentDetailsSheet> createState() => _PaymentDetailsSheetState();
}

class _PaymentDetailsSheetState extends State<_PaymentDetailsSheet> {
  static const _banks = [
    'Maybank',
    'CIMB Bank',
    'Public Bank',
    'RHB Bank',
    'Hong Leong Bank',
    'AmBank',
    'Bank Islam',
  ];

  final _formKey = GlobalKey<FormState>();
  final _primary = TextEditingController();
  final _secondary = TextEditingController();
  final _expiry = TextEditingController();
  final _cvv = TextEditingController();
  String? _bank;

  @override
  void dispose() {
    _primary.dispose();
    _secondary.dispose();
    _expiry.dispose();
    _cvv.dispose();
    super.dispose();
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  String _lastFour(String v) {
    final digits = v.replaceAll(RegExp(r'\D'), '');
    return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final summary = switch (widget.method.kind) {
      PaymentMethodKind.bank => '$_bank •••• ${_lastFour(_secondary.text)}',
      PaymentMethodKind.card => 'Card •••• ${_lastFour(_primary.text)}',
      PaymentMethodKind.eWallet => 'Linked to •••• ${_lastFour(_primary.text)}',
      PaymentMethodKind.googlePay => _primary.text.trim(),
    };
    Navigator.of(context).pop(summary);
  }

  List<Widget> _fields() {
    switch (widget.method.kind) {
      case PaymentMethodKind.bank:
        return [
          DropdownButtonFormField<String>(
            initialValue: _bank,
            decoration: const InputDecoration(labelText: 'BANK'),
            items: [
              for (final b in _banks)
                DropdownMenuItem(value: b, child: Text(b)),
            ],
            onChanged: (v) => setState(() => _bank = v),
            validator: (v) => v == null ? 'Select a bank' : null,
          ),
          TextFormField(
            controller: _primary,
            decoration: const InputDecoration(labelText: 'ACCOUNT HOLDER NAME'),
            textCapitalization: TextCapitalization.words,
            validator: _required,
          ),
          TextFormField(
            controller: _secondary,
            decoration: const InputDecoration(labelText: 'ACCOUNT NUMBER'),
            keyboardType: TextInputType.number,
            validator: _required,
          ),
        ];
      case PaymentMethodKind.card:
        return [
          TextFormField(
            controller: _primary,
            decoration: const InputDecoration(
              labelText: 'CARD NUMBER',
              hintText: '1234 5678 9012 3456',
            ),
            keyboardType: TextInputType.number,
            validator: (v) =>
                (v ?? '').replaceAll(RegExp(r'\D'), '').length < 12
                ? 'Enter a valid card number'
                : null,
          ),
          TextFormField(
            controller: _secondary,
            decoration: const InputDecoration(labelText: 'NAME ON CARD'),
            textCapitalization: TextCapitalization.characters,
            validator: _required,
          ),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _expiry,
                  decoration: const InputDecoration(
                    labelText: 'EXPIRY',
                    hintText: 'MM/YY',
                  ),
                  keyboardType: TextInputType.datetime,
                  validator: _required,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _cvv,
                  decoration: const InputDecoration(labelText: 'CVV'),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  validator: _required,
                ),
              ),
            ],
          ),
        ];
      case PaymentMethodKind.eWallet:
        return [
          TextFormField(
            controller: _primary,
            decoration: const InputDecoration(
              labelText: 'PHONE NUMBER',
              prefixText: '+60 ',
              hintText: '12 345 6789',
            ),
            keyboardType: TextInputType.phone,
            validator: _required,
          ),
        ];
      case PaymentMethodKind.googlePay:
        return [
          TextFormField(
            controller: _primary,
            decoration: const InputDecoration(
              labelText: 'GOOGLE ACCOUNT EMAIL',
              hintText: 'name@gmail.com',
            ),
            keyboardType: TextInputType.emailAddress,
            validator: (v) =>
                (v ?? '').contains('@') ? null : 'Enter a valid email',
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.method;
    final fields = _fields();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: RPColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    PaymentLogo(method: m, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Connect ${m.name}',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: RPColors.textDark,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                for (final f in fields) ...[f, const SizedBox(height: 14)],
                const SizedBox(height: 6),
                ElevatedButton(
                  onPressed: _submit,
                  child: const Text('Connect'),
                ),
                const SizedBox(height: 10),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: RPColors.textGrey,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Demo only. No payment details are stored.',
                      style: TextStyle(fontSize: 12, color: RPColors.textGrey),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
