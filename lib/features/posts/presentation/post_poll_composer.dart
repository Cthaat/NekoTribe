import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../domain/post_poll.dart';

class PostPollComposer extends StatefulWidget {
  const PostPollComposer({
    super.key,
    required this.onChanged,
    this.enabled = true,
    this.initial,
  });

  final ValueChanged<V2CreatePostPoll?> onChanged;
  final bool enabled;
  final V2CreatePostPoll? initial;

  @override
  State<PostPollComposer> createState() => _PostPollComposerState();
}

class _PostPollComposerState extends State<PostPollComposer> {
  late bool _attached = widget.initial != null;
  late bool _multiple = widget.initial?.multiple ?? false;
  late DateTime? _closesAt = widget.initial?.closesAt.toLocal();
  late final List<String> _options = [...?widget.initial?.options];

  @override
  void initState() {
    super.initState();
    if (widget.initial == null) _options.addAll(['', '']);
  }

  V2CreatePostPoll _draft() => V2CreatePostPoll(
    options: List.unmodifiable(_options),
    multiple: _multiple,
    closesAt: _closesAt!,
  );

  void _change(VoidCallback update) {
    setState(update);
    widget.onChanged(_attached ? _draft() : null);
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final initial = _closesAt!.isAfter(now) ? _closesAt! : now;
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      initialDate: initial,
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || !widget.enabled || !_attached || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted || !widget.enabled || !_attached || time == null) return;
    _change(() {
      _closesAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final materials = MaterialLocalizations.of(context);
    final draft = _attached ? _draft() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const Key('post-poll-attach'),
          title: Text(l10n.t('poll.attach')),
          contentPadding: EdgeInsets.zero,
          value: _attached,
          onChanged: !widget.enabled
              ? null
              : (value) => _change(() {
                  _attached = value ?? false;
                  _closesAt ??= DateTime.now()
                      .add(const Duration(days: 1))
                      .copyWith(second: 0, millisecond: 0, microsecond: 0);
                }),
        ),
        if (draft != null) ...[
          for (var index = 0; index < _options.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextFormField(
                key: ValueKey('post-poll-option-${index + 1}'),
                enabled: widget.enabled,
                initialValue: _options[index],
                decoration: InputDecoration(
                  labelText: l10n
                      .t('poll.option')
                      .replaceFirst('{number}', '${index + 1}'),
                ),
                onChanged: (value) => _change(() => _options[index] = value),
              ),
            ),
          if (!draft.hasValidOptions) Text(l10n.t('poll.invalid_options')),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed:
                    widget.enabled &&
                        _options.length < V2CreatePostPoll.maxOptions
                    ? () => _change(() => _options.add(''))
                    : null,
                icon: const Icon(Icons.add),
                label: Text(l10n.t('poll.add_option')),
              ),
              if (_options.length > V2CreatePostPoll.minOptions)
                TextButton(
                  onPressed: widget.enabled
                      ? () => _change(_options.removeLast)
                      : null,
                  child: Text(l10n.t('poll.remove_last_option')),
                ),
            ],
          ),
          CheckboxListTile(
            key: const Key('post-poll-multiple'),
            title: Text(l10n.t('poll.multiple')),
            contentPadding: EdgeInsets.zero,
            value: _multiple,
            onChanged: !widget.enabled
                ? null
                : (value) => _change(() => _multiple = value ?? false),
          ),
          OutlinedButton.icon(
            onPressed: widget.enabled ? _pickDeadline : null,
            icon: const Icon(Icons.schedule),
            label: Text(
              l10n
                  .t('poll.closes_at')
                  .replaceFirst(
                    '{date}',
                    '${materials.formatShortDate(draft.closesAt)} '
                        '${TimeOfDay.fromDateTime(draft.closesAt).format(context)}',
                  ),
            ),
          ),
          if (!draft.closesAt.isAfter(DateTime.now()))
            Text(l10n.t('poll.invalid_deadline')),
        ],
      ],
    );
  }
}
