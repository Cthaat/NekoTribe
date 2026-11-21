import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../domain/group_models.dart';

class GroupAuditLogScreen extends ConsumerStatefulWidget {
  const GroupAuditLogScreen({super.key, required this.groupId});

  final int groupId;

  @override
  ConsumerState<GroupAuditLogScreen> createState() =>
      _GroupAuditLogScreenState();
}

class _GroupAuditLogScreenState extends ConsumerState<GroupAuditLogScreen> {
  CancelToken? _current;
  late final VoidCallback _stopListening;
  List<V2GroupAuditEntry> _items = [];
  int _page = 1;
  bool _next = false, _failed = false, _expired = false;

  @override
  void initState() {
    super.initState();
    _stopListening = ref.read(tokenStoreProvider).listenSessionChanges(() {
      _current?.cancel();
      if (!mounted) return;
      setState(() {
        _current = null;
        _items = [];
        _next = false;
        _expired = true;
      });
    });
    _load(1);
  }

  @override
  void dispose() {
    _stopListening();
    _current?.cancel();
    super.dispose();
  }

  Future<void> _load(int page) async {
    if (_current != null || _expired) return;
    final request = CancelToken();
    setState(() {
      _current = request;
      _page = page;
      _items = [];
      _next = false;
      _failed = false;
    });
    try {
      final result = await ref
          .read(groupsApiProvider)
          .auditLogs(widget.groupId, page: page, cancelToken: request);
      if (!mounted || _current != request) return;
      if (result.items.any((entry) => entry.groupId != widget.groupId)) {
        throw const FormatException('Invalid audit scope');
      }
      setState(() {
        _current = null;
        _items = result.items;
        _next = result.hasNext;
      });
    } catch (_) {
      if (!mounted || _current != request) return;
      setState(() {
        _current = null;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(String key) => l10n.t('group.audit.$key');
    String idLabel(String key, int id) => label(key).replaceAll('{id}', '$id');
    return Scaffold(
      appBar: AppBar(title: Text(label('title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_current != null)
            const LinearProgressIndicator()
          else if (_expired)
            Text(label('expired'))
          else if (_failed)
            Text(label('failed'))
          else if (_items.isEmpty)
            Text(label('empty')),
          for (final entry in _items)
            Card(
              child: ExpansionTile(
                key: ValueKey(entry.id),
                title: Text(entry.action),
                subtitle: Text(
                  '${idLabel('actor', entry.actorId)}\n${entry.createdAt}',
                ),
                children: [
                  if (entry.targetUserId case final id?)
                    ListTile(title: Text(idLabel('user', id))),
                  if (entry.targetPostId case final id?)
                    ListTile(title: Text(idLabel('post', id))),
                  if (entry.targetCommentId case final id?)
                    ListTile(title: Text(idLabel('comment', id))),
                  if (entry.details case final details?)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        details is String
                            ? details
                            : const JsonEncoder.withIndent(
                                '  ',
                              ).convert(details),
                      ),
                    ),
                ],
              ),
            ),
          if (!_expired && _current == null)
            Wrap(
              spacing: 8,
              children: [
                if (_failed)
                  OutlinedButton(
                    onPressed: () => _load(_page),
                    child: Text(label('retry')),
                  ),
                if (_page > 1)
                  OutlinedButton(
                    onPressed: () => _load(_page - 1),
                    child: Text(label('previous')),
                  ),
                if (_next)
                  OutlinedButton(
                    onPressed: () => _load(_page + 1),
                    child: Text(label('next')),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
