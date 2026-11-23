import 'dart:convert';

import '../../../core/utils/json_utils.dart';

class V2CreatePostPoll {
  const V2CreatePostPoll({
    required this.options,
    required this.multiple,
    required this.closesAt,
  });

  static const minOptions = 2;
  static const maxOptions = 6;
  static const maxOptionBytes = 240;

  final List<String> options;
  final bool multiple;
  final DateTime closesAt;

  bool get hasValidOptions {
    final texts = options.map((option) => option.trim()).toList();
    return texts.length >= minOptions &&
        texts.length <= maxOptions &&
        texts.toSet().length == texts.length &&
        texts.every(
          (text) =>
              text.isNotEmpty && utf8.encode(text).length <= maxOptionBytes,
        );
  }

  bool get isValid => hasValidOptions && closesAt.isAfter(DateTime.now());

  Map<String, Object> toJson() => {
    'options': options.map((option) => option.trim()).toList(),
    'multiple': multiple,
    'closes_at': closesAt.toUtc().toIso8601String(),
  };
}

class V2PostPoll {
  const V2PostPoll({
    required this.pollId,
    required this.multiple,
    required this.closesAt,
    required this.closed,
    required this.totalBallots,
    required this.myOptionIds,
    required this.options,
  });

  final int pollId;
  final bool multiple;
  final DateTime closesAt;
  final bool closed;
  final int totalBallots;
  final List<int> myOptionIds;
  final List<V2PostPollOption> options;

  static V2PostPoll? optional(Object? value) =>
      value == null ? null : V2PostPoll.fromJson(toMap(value));

  factory V2PostPoll.fromJson(Map<String, dynamic> json) {
    final id = json['poll_id'];
    final multiple = json['multiple'];
    final closesAt = toDateTime(json['closes_at']);
    final closed = json['closed'];
    final total = json['total_ballots'];
    final options = json['options'];
    final choices = json['my_option_ids'];
    if (id is! int ||
        id < 1 ||
        id > 9007199254740991 ||
        multiple is! bool ||
        closesAt == null ||
        closed is! bool ||
        total is! int ||
        total < 0 ||
        options is! List ||
        options.length < V2CreatePostPoll.minOptions ||
        options.length > V2CreatePostPoll.maxOptions ||
        choices is! List ||
        (!multiple && choices.length > 1) ||
        choices.toSet().length != choices.length ||
        choices.any((id) => id is! int || id < 1 || id > options.length)) {
      throw const FormatException('Invalid post poll response');
    }
    return V2PostPoll(
      pollId: id,
      multiple: multiple,
      closesAt: closesAt,
      closed: closed,
      totalBallots: total,
      myOptionIds: List<int>.unmodifiable(choices.cast<int>()),
      options: List<V2PostPollOption>.unmodifiable(
        List.generate(
          options.length,
          (index) =>
              V2PostPollOption.fromJson(toMap(options[index]), index + 1),
        ),
      ),
    );
  }
}

class V2PostPollOption {
  const V2PostPollOption({
    required this.optionId,
    required this.text,
    required this.votesCount,
    required this.percent,
  });

  final int optionId;
  final String text;
  final int votesCount;
  final double percent;

  factory V2PostPollOption.fromJson(Map<String, dynamic> json, int expectedId) {
    final id = json['option_id'];
    final text = json['text'];
    final votes = json['votes_count'];
    final percent = json['percent'];
    if (id is! int ||
        id != expectedId ||
        text is! String ||
        text.isEmpty ||
        votes is! int ||
        votes < 0 ||
        percent is! num ||
        !percent.isFinite ||
        percent < 0 ||
        percent > 100) {
      throw const FormatException('Invalid post poll option');
    }
    return V2PostPollOption(
      optionId: id,
      text: text,
      votesCount: votes,
      percent: percent.toDouble(),
    );
  }
}
