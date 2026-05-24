import 'package:flutter/material.dart';

class BillingScreen extends StatelessWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Billing')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _MetricTile(
            icon: Icons.wallet_outlined,
            label: 'Current plan',
            value: 'Free',
          ),
          _MetricTile(
            icon: Icons.event_outlined,
            label: 'Next billing date',
            value: '2026-06-18',
          ),
          _MetricTile(
            icon: Icons.verified_user_outlined,
            label: 'Billing status',
            value: 'Active',
          ),
          SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: Icon(Icons.receipt_long_outlined),
              title: Text('NT-2026-005'),
              subtitle: Text('2026-05-18'),
              trailing: Text('Pending'),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.receipt_long_outlined),
              title: Text('NT-2026-004'),
              subtitle: Text('2026-04-18'),
              trailing: Text('Paid'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Text(value),
      ),
    );
  }
}
