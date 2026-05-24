import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';

class GroupManageScreen extends ConsumerStatefulWidget {
  const GroupManageScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<GroupManageScreen> createState() => _GroupManageScreenState();
}

class _GroupManageScreenState extends ConsumerState<GroupManageScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  V2Group? _group;
  List<V2GroupMember> _members = [];
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      final members = await api.members(group.groupId);
      if (!mounted) return;
      setState(() {
        _group = group;
        _members = members.items;
        _name.text = group.name;
        _description.text = group.description;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_group == null || _saving) return;
    setState(() => _saving = true);
    try {
      final next = await ref.read(groupsApiProvider).updateGroup(
        _group!.groupId,
        {'name': _name.text.trim(), 'description': _description.text.trim()},
      );
      if (!mounted) return;
      setState(() => _group = next);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Group updated')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createInvite() async {
    if (_group == null) return;
    try {
      await ref.read(groupsApiProvider).createInvite(_group!.groupId, {});
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invite created')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage group')),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Name',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _description,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Description',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
                OutlinedButton.icon(
                  onPressed: _createInvite,
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('Create invite'),
                ),
                const SizedBox(height: 20),
                Text('Members', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final member in _members)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(member.user.displayName),
                      subtitle: Text('@${member.user.username}'),
                      trailing: Text(member.role),
                    ),
                  ),
              ],
            ),
    );
  }
}
