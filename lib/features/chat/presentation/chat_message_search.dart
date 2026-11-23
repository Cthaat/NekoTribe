import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/widgets/status_views.dart';

typedef ChatSearchSender = ({int id, String name});

class ChatMessageFilters {
  const ChatMessageFilters({
    this.query = '',
    this.senderId,
    this.startAt,
    this.endAt,
  });

  final String query;
  final int? senderId;
  final DateTime? startAt;
  final DateTime? endAt;

  bool get active =>
      query.isNotEmpty || senderId != null || startAt != null || endAt != null;
}

class ChatMessageSearch extends StatefulWidget {
  const ChatMessageSearch({
    super.key,
    required this.inputKey,
    required this.title,
    required this.loadSenders,
    required this.isCurrent,
    required this.onApply,
    required this.onClear,
  });

  final Key inputKey;
  final String title;
  final Future<List<ChatSearchSender>> Function() loadSenders;
  final bool Function() isCurrent;
  final ValueChanged<ChatMessageFilters> onApply;
  final VoidCallback onClear;

  @override
  State<ChatMessageSearch> createState() => _ChatMessageSearchState();
}

class _ChatMessageSearchState extends State<ChatMessageSearch> {
  final _query = TextEditingController();
  DateTime? _startDate, _endDate;
  ChatSearchSender? _sender;
  Future<List<ChatSearchSender>>? _senders;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _apply() {
    if (!widget.isCurrent()) return;
    final query = _query.text.trim();
    final start = _startDate;
    final end = _endDate;
    final startAt = start == null
        ? null
        : DateTime(start.year, start.month, start.day).toUtc();
    final endAt = end == null
        ? null
        : DateTime(end.year, end.month, end.day + 1).toUtc();
    final error = utf8.encode(query).length > 400
        ? 'chat.search_query_too_long'
        : startAt != null && endAt != null && !startAt.isBefore(endAt)
        ? 'chat.search_date_range'
        : null;
    setState(() {
      _error = error;
      _senders = null;
    });
    if (error != null) return;
    FocusScope.of(context).unfocus();
    widget.onApply(
      ChatMessageFilters(
        query: query,
        senderId: _sender?.id,
        startAt: startAt,
        endAt: endAt,
      ),
    );
  }

  Future<void> _pickDate({required bool start}) async {
    final current = widget.isCurrent;
    if (!current()) return;
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: (start ? _startDate : _endDate) ?? now,
      firstDate: DateTime(1970),
      lastDate: DateTime(now.year + 10, 12, 31),
      helpText: AppLocalizations.of(
        context,
      ).t(start ? 'chat.search_start_date' : 'chat.search_end_date'),
    );
    if (!mounted || !current() || date == null) return;
    setState(() {
      if (start) {
        _startDate = date;
      } else {
        _endDate = date;
      }
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dateFormat = MaterialLocalizations.of(context);
    final senders = _senders;
    Widget dateChip(String key, DateTime? date, {required bool start}) =>
        InputChip(
          label: Text(
            date == null
                ? l10n.t(key)
                : '${l10n.t(key)} ${dateFormat.formatCompactDate(date)}',
          ),
          avatar: const Icon(Icons.calendar_today_outlined, size: 16),
          onPressed: () => _pickDate(start: start),
          onDeleted: date == null
              ? null
              : () => setState(() {
                  if (start) {
                    _startDate = null;
                  } else {
                    _endDate = null;
                  }
                  _error = null;
                }),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: widget.inputKey,
            controller: _query,
            onTap: () {
              if (_senders != null) setState(() => _senders = null);
            },
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _apply(),
            decoration: InputDecoration(
              labelText: widget.title,
              errorText: _error == null ? null : l10n.t(_error!),
              suffixIcon: IconButton(
                tooltip: l10n.t('common.search'),
                onPressed: _apply,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InputChip(
                label: Text(_sender?.name ?? l10n.t('chat.search_sender')),
                avatar: const Icon(Icons.person_outline, size: 16),
                onPressed: () {
                  if (!widget.isCurrent()) return;
                  FocusScope.of(context).unfocus();
                  final pending = senders == null ? widget.loadSenders() : null;
                  setState(() {
                    _senders = pending;
                  });
                },
                onDeleted: _sender == null
                    ? null
                    : () => setState(() => _sender = null),
              ),
              dateChip('chat.search_start_date', _startDate, start: true),
              dateChip('chat.search_end_date', _endDate, start: false),
              TextButton(
                onPressed: () {
                  if (widget.isCurrent()) widget.onClear();
                },
                child: Text(l10n.t('chat.search_clear')),
              ),
            ],
          ),
          if (senders != null)
            FutureBuilder<List<ChatSearchSender>>(
              future: senders,
              builder: (context, snapshot) {
                if (!widget.isCurrent()) return const SizedBox.shrink();
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                if (snapshot.hasError) {
                  return Text(ErrorView.describe(context, snapshot.error!));
                }
                final items = snapshot.data ?? const <ChatSearchSender>[];
                if (items.isEmpty) {
                  return Text(l10n.t('chat.search_no_senders'));
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 144),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final sender = items[index];
                      return ListTile(
                        dense: true,
                        title: Text(sender.name),
                        selected: _sender?.id == sender.id,
                        onTap: () {
                          if (!widget.isCurrent()) return;
                          setState(() {
                            _sender = sender;
                            _senders = null;
                          });
                        },
                      );
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
