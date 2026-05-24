import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ProScreen extends StatelessWidget {
  const ProScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NekoTribe Pro')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Upgrade-ready workspace',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'NekoTribe Pro surfaces AI assistance, realtime collaboration, advanced safety tooling, and higher operational limits when billing is enabled.',
          ),
          const SizedBox(height: 16),
          const _FeatureTile(
            icon: Icons.psychology_outlined,
            title: 'AI sentiment workflows',
            subtitle:
                'Tune model output from account settings and composer flows.',
          ),
          const _FeatureTile(
            icon: Icons.forum_outlined,
            title: 'Realtime community tools',
            subtitle:
                'Direct messages and group channels stay available on every platform.',
          ),
          const _FeatureTile(
            icon: Icons.shield_outlined,
            title: 'Safety dashboard',
            subtitle:
                'Moderation queues, appeals, and reports share one mobile-friendly surface.',
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => context.push('/settings/billing'),
            icon: const Icon(Icons.credit_card),
            label: const Text('View billing'),
          ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }
}
