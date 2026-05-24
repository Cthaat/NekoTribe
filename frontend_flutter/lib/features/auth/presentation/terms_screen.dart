import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms of Service'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/feed'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('NekoTribe Terms', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Last updated: 2025-07-16',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          const _Section(
            title: '1. Acceptance',
            body:
                'By using NekoTribe, you agree to follow these terms and the community rules that keep the service safe.',
          ),
          const _Section(
            title: '2. Accounts',
            body:
                'You are responsible for your account activity, credentials, and the information you choose to publish.',
          ),
          const _Section(
            title: '3. Conduct',
            body:
                'Do not harass others, publish illegal content, abuse platform features, or evade moderation actions.',
          ),
          const _Section(
            title: '4. Termination',
            body:
                'Accounts or content may be limited when they violate safety, legal, or platform integrity requirements.',
          ),
          const _Section(
            title: '5. Questions',
            body:
                'Use the feedback links in the About page or account statements flow if you need review or support.',
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body),
        ],
      ),
    );
  }
}
