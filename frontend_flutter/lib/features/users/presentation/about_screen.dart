import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About NekoTribe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('NekoTribe', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'A multi-platform social community for posts, groups, realtime chat, notifications, moderation, and AI-assisted sentiment insight.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text('Social feed')),
              Chip(label: Text('Groups')),
              Chip(label: Text('Realtime chat')),
              Chip(label: Text('Safety')),
              Chip(label: Text('SentimentFlow')),
            ],
          ),
          const SizedBox(height: 24),
          _ActionTile(
            icon: Icons.explore_outlined,
            title: 'Explore posts',
            subtitle: 'Browse public timeline and trending content.',
            onTap: () => context.go('/discover'),
          ),
          _ActionTile(
            icon: Icons.group_outlined,
            title: 'Groups',
            subtitle: 'Open group discovery when you are signed in.',
            onTap: () => context.go('/groups'),
          ),
          _ActionTile(
            icon: Icons.article_outlined,
            title: 'Terms',
            subtitle: 'Read the NekoTribe service terms.',
            onTap: () => context.push('/auth/terms'),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
