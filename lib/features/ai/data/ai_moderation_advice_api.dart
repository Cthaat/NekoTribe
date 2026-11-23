import 'ai_stream.dart';

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/json_utils.dart';
import 'ai_conversation_page.dart';
import 'ai_model_version.dart';

typedef ModerationAdviceTarget = ({String kind, int id});
typedef ModerationRule = ({int id, String version});
typedef ModerationAdviceSource = ({int postId, int? groupId, int? commentId});
typedef ModerationAdvice = ({
  String risk,
  String reason,
  String recommendation,
  ModerationAnalysisMode analysisMode,
  List<ModerationRule> rules,
  ModerationAdviceSource? source,
});
typedef ModerationAdviceMessage = ({
  String id,
  String conversationId,
  int sequence,
  String createdAt,
  String? modelVersion,
  int? configRevision,
  ModerationAdvice? advice,
  ModerationRating? rating,
});
typedef ModerationAdviceHistory = ({
  String? conversationId,
  int sequence,
  List<ModerationAdviceMessage> messages,
  Map<String, ModerationHistoryCursor> older,
  Map<String, int> latestSequences,
});
typedef ModerationHistoryCursor = ({int before, bool forwardOnly});
typedef _HistoryRow = ({int sequence, ModerationAdviceMessage? message});

enum ModerationAnalysisMode { textOnly, textAndImages }

enum ModerationRating {
  helpful,
  incorrect,
  insufficient;

  static ModerationRating? parse(Object? value) {
    for (final rating in values) {
      if (rating.name == value) return rating;
    }
    return null;
  }
}

const _targets = {'post', 'comment', 'group_post', 'group_post_comment'};
const _risks = {
  'none',
  'spam',
  'harassment',
  'hate',
  'violence',
  'adult',
  'misinformation',
  'copyright',
  'other',
};
const _recommendations = {'no_action', 'human_review', 'consider_removal'};
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _versionPattern = RegExp(r'^[0-9a-f]{64}$');

int? _sourceId(Object? value) =>
    value is num &&
        value >= 1 &&
        value <= 999999999999999 &&
        value == value.truncate()
    ? value.toInt()
    : null;

ModerationAdviceTarget? moderationAdviceTarget(String kind, int id) {
  final normalized = kind == 'group_comment' ? 'group_post_comment' : kind;
  return _targets.contains(normalized) && id > 0 && id <= 999999999999999
      ? (kind: normalized, id: id)
      : null;
}

String? _uuid(Object? value) =>
    value is String && value.length == 36 && _uuidPattern.hasMatch(value)
    ? value
    : null;

ModerationAdvice? _parseAdvice(Object? raw, ModerationAdviceTarget target) {
  if (raw == null) return null;
  final advice = toMap(raw);
  final source = toMap(advice['target']);
  if (source['kind'] != target.kind || source['id'] != target.id) return null;
  final risk = advice['risk'];
  final reason = advice['reason'];
  final recommendation = advice['recommendation'];
  final analysisMode = switch (advice['analysis_mode']) {
    null || 'text_only' => ModerationAnalysisMode.textOnly,
    'text_and_images' => ModerationAnalysisMode.textAndImages,
    _ => throw const FormatException('Invalid moderation analysis mode'),
  };
  final rules = advice['rules'];
  final ids = advice['rule_ids'];
  if (risk is! String ||
      !_risks.contains(risk) ||
      recommendation is! String ||
      !_recommendations.contains(recommendation) ||
      reason is! String ||
      reason.trim().isEmpty ||
      utf8.encode(reason).length > 1200 ||
      rules is! List ||
      rules.isEmpty ||
      rules.length > 4 ||
      ids is! List ||
      ids.length != rules.length ||
      ids.toSet().length != rules.length) {
    throw const FormatException('Invalid moderation advice');
  }
  final unseen = ids.toSet();
  final parsedRules = <ModerationRule>[];
  for (final rawRule in rules) {
    final rule = toMap(rawRule);
    final id = rule['id'], version = rule['version'];
    if (rule['kind'] != 'terms' ||
        id is! int ||
        id < 1 ||
        id > 8 ||
        !unseen.remove(id) ||
        version is! String ||
        version.length != 64 ||
        !_versionPattern.hasMatch(version)) {
      throw const FormatException('Invalid moderation rule');
    }
    parsedRules.add((id: id, version: version));
  }
  final postId = _sourceId(source['post_id']);
  final groupId = _sourceId(source['group_id']);
  final grouped =
      target.kind == 'group_post' || target.kind == 'group_post_comment';
  final comment =
      target.kind == 'comment' || target.kind == 'group_post_comment';
  final location =
      postId != null &&
          (comment || postId == target.id) &&
          (grouped ? groupId != null : source['group_id'] == null)
      ? (
          postId: postId,
          groupId: groupId,
          commentId: comment ? target.id : null,
        )
      : null;
  return (
    risk: risk,
    reason: reason,
    recommendation: recommendation,
    analysisMode: analysisMode,
    rules: parsedRules,
    source: location,
  );
}

class AiModerationAdviceApi {
  AiModerationAdviceApi(this._client);
  final ApiClient _client;

  String _path(String id) =>
      '${ApiPaths.aiConversations}/${Uri.encodeComponent(id)}';
  String _title(ModerationAdviceTarget target) =>
      'moderation:${target.kind}:${target.id}';

  Future<ModerationAdviceHistory> history(
    ModerationAdviceTarget target,
    CancelToken cancel,
  ) async {
    final messages = <ModerationAdviceMessage>[];
    final older = <String, ModerationHistoryCursor>{};
    final latestSequences = <String, int>{};
    String? after;
    do {
      final cursor = after;
      final page = await _client.requestData(
        ApiPaths.aiConversations,
        query: {
          'limit': 50,
          'purpose': 'moderation',
          'target_type': target.kind,
          'target_id': target.id,
          if (cursor != null) 'after_id': cursor,
        },
        cancelToken: cancel,
        decode: toMap,
      );
      final items = page['items'];
      if (items is! List || items.length > 50) {
        throw const FormatException('Invalid moderation conversation page');
      }
      final entries = items.map((raw) {
        final row = toMap(raw);
        final id = _uuid(row['conversation_id']);
        if (id == null) {
          throw const FormatException('Invalid moderation conversation');
        }
        return (id: id, row: row);
      }).toList();
      final next = validateAiConversationPage(
        entries.map((entry) => entry.id),
        cursor,
        page['next_cursor'],
      );
      for (final (:id, :row) in entries) {
        if (row['purpose'] != 'moderation' ||
            row['group_id'] != null ||
            row['title'] != _title(target)) {
          continue;
        }
        try {
          final entry = await _readConversation(id, target, cancel);
          latestSequences[id] = entry.rows.lastOrNull?.sequence ?? 0;
          messages.addAll(_visibleMessages(entry.rows));
          final before = entry.rows.firstOrNull?.sequence ?? 0;
          if (entry.rows.length == 50 && before > 1) {
            older[id] = (before: before, forwardOnly: entry.forwardOnly);
          }
        } on ApiException catch (error) {
          if (!error.isNotFound) rethrow;
        }
      }
      after = next;
    } while (after != null);
    return _assembleHistory(latestSequences, messages, older);
  }

  Future<ModerationAdviceHistory> older(
    ModerationAdviceHistory previous,
    ModerationAdviceTarget target,
    CancelToken cancel,
  ) async {
    final messages = [...previous.messages];
    final older = <String, ModerationHistoryCursor>{};
    final latestSequences = {...previous.latestSequences};
    for (final MapEntry(key: id, value: cursor) in previous.older.entries) {
      try {
        final rows = cursor.forwardOnly
            ? await _readForwardPage(id, target, cancel, before: cursor.before)
            : await _readPage(id, target, cancel, before: cursor.before);
        final first = rows.firstOrNull?.sequence ?? 0;
        if (rows.length == 50 && first > 1) {
          older[id] = (before: first, forwardOnly: cursor.forwardOnly);
        }
        messages.addAll(_visibleMessages(rows));
      } on ApiException catch (error) {
        if (!error.isNotFound) rethrow;
        latestSequences.remove(id);
      }
    }
    return _assembleHistory(latestSequences, messages, older);
  }

  ModerationAdviceHistory _assembleHistory(
    Map<String, int> latestSequences,
    List<ModerationAdviceMessage> messages,
    Map<String, ModerationHistoryCursor> older,
  ) {
    final selected = latestSequences.entries.firstOrNull;
    final remaining =
        messages
            .where(
              (message) => latestSequences.containsKey(message.conversationId),
            )
            .toList()
          ..sort((a, b) {
            final order = b.createdAt.compareTo(a.createdAt);
            return order == 0 ? b.id.compareTo(a.id) : order;
          });
    return (
      conversationId: selected?.key,
      sequence: selected?.value ?? 0,
      messages: remaining,
      older: older,
      latestSequences: latestSequences,
    );
  }

  Iterable<ModerationAdviceMessage> _visibleMessages(List<_HistoryRow> rows) =>
      rows.map((row) => row.message).whereType<ModerationAdviceMessage>();

  Future<({List<_HistoryRow> rows, bool forwardOnly})> _readConversation(
    String id,
    ModerationAdviceTarget target,
    CancelToken cancel,
  ) async {
    final head = await _readPage(id, target, cancel, before: 10000000000);
    // Older servers may ignore before_sequence and return their first page.
    final forwardOnly = head.length == 50 && head.first.sequence == 1;
    final rows = forwardOnly
        ? await _readForwardPage(id, target, cancel, initial: head)
        : head;
    return (rows: rows, forwardOnly: forwardOnly);
  }

  Future<List<_HistoryRow>> _readForwardPage(
    String id,
    ModerationAdviceTarget target,
    CancelToken cancel, {
    List<_HistoryRow> initial = const [],
    int before = 10000000000,
  }) async {
    final entries = [...initial];
    var after = entries.lastOrNull?.sequence ?? 0;
    while (!cancel.isCancelled) {
      final page = await _readPage(id, target, cancel, after: after);
      entries.addAll(page.where((row) => row.sequence < before));
      if (entries.length > 50) entries.removeRange(0, entries.length - 50);
      final last = page.lastOrNull?.sequence ?? after;
      if (page.length < 50 || last >= before) return entries;
      after = last;
    }
    throw cancel.cancelError!;
  }

  Future<List<_HistoryRow>> _readPage(
    String id,
    ModerationAdviceTarget target,
    CancelToken cancel, {
    int after = 0,
    int? before,
    int limit = 50,
  }) async {
    final parsed = <_HistoryRow>[];
    var sequence = after;
    final rows = await _client.requestData<List<Object?>>(
      '${_path(id)}/messages',
      query: {
        if (before == null)
          'after_sequence': after
        else
          'before_sequence': before,
        'limit': limit,
      },
      cancelToken: cancel,
      decode: (raw) {
        if (raw is! List || raw.length > limit) {
          throw const FormatException('Invalid moderation history');
        }
        return raw.cast<Object?>();
      },
    );
    final ids = <String>{};
    for (final raw in rows) {
      final row = toMap(raw);
      final messageId = _uuid(row['message_id']);
      final next = row['sequence_no'], createdAt = row['created_at'];
      if (messageId == null ||
          !ids.add(messageId) ||
          row['conversation_id'] != id ||
          next is! int ||
          next <= sequence ||
          next > 9999999999 ||
          (before != null && next >= before) ||
          createdAt is! String) {
        throw const FormatException('Invalid moderation message');
      }
      sequence = next;
      ModerationAdviceMessage? message;
      if (row['role'] == 'assistant') {
        final advice = _parseAdvice(row['moderation_advice'], target);
        message = (
          id: messageId,
          conversationId: id,
          sequence: next,
          createdAt: createdAt,
          modelVersion: aiModelVersion(row['role'], row['model_version']),
          configRevision: aiReplyConfigRevision(
            row['role'],
            row['config_revision'],
          ),
          advice: advice,
          rating: advice == null
              ? null
              : ModerationRating.parse(row['moderation_feedback']),
        );
      }
      parsed.add((sequence: sequence, message: message));
    }
    return parsed;
  }

  Future<void> remove(String id, CancelToken cancel) async {
    await _client.request<void>(
      _path(id),
      method: 'DELETE',
      cancelToken: cancel,
      decode: (data) {
        if (data != null) throw const FormatException('Invalid delete receipt');
      },
    );
  }

  Future<ModerationAdviceMessage?> rate(
    ModerationAdviceMessage message,
    ModerationRating rating,
    ModerationAdviceTarget target,
    CancelToken cancel,
  ) async {
    await _client.requestData<void>(
      '${_path(message.conversationId)}/messages/${Uri.encodeComponent(message.id)}/moderation-feedback',
      method: 'PUT',
      data: {'rating': rating.name},
      cancelToken: cancel,
      decode: (raw) {
        final receipt = toMap(raw);
        if (receipt['message_id'] != message.id ||
            receipt['rating'] != rating.name) {
          throw const FormatException('Invalid moderation feedback receipt');
        }
      },
    );
    final rows = await _readPage(
      message.conversationId,
      target,
      cancel,
      after: message.sequence - 1,
      limit: 1,
    );
    final confirmed = rows.firstOrNull?.message;
    return confirmed != null &&
            confirmed.id == message.id &&
            confirmed.sequence == message.sequence &&
            confirmed.advice != null &&
            confirmed.rating == rating
        ? confirmed
        : null;
  }

  Future<String> create(ModerationAdviceTarget target, CancelToken cancel) {
    final title = _title(target);
    return _client.requestData(
      ApiPaths.aiConversations,
      method: 'POST',
      data: {'purpose': 'moderation', 'title': title},
      cancelToken: cancel,
      decode: (raw) {
        final row = toMap(raw);
        final id = _uuid(row['conversation_id']);
        if (id == null ||
            row['purpose'] != 'moderation' ||
            row['group_id'] != null ||
            row['title'] != title) {
          throw const FormatException('Invalid moderation conversation');
        }
        return id;
      },
    );
  }

  Future<bool> generate(
    String id,
    ModerationAdviceTarget target,
    String locale,
    int sequence,
    CancelToken cancel, {
    bool selectSkill = false,
    void Function(String)? onDelta,
  }) => generateAiData<bool>(
    _client,
    '${_path(id)}/moderation-generate',
    method: 'POST',
    data: {
      'target_type': target.kind,
      'target_id': target.id,
      'locale': locale,
      'expected_sequence': sequence,
      if (selectSkill) 'skill_id': 'moderation-advice',
    },
    cancelToken: cancel,
    onDelta: onDelta,
    decode: (raw) {
      final data = toMap(raw);
      if (data['status'] == 'insufficient_evidence' &&
          data['message'] == null) {
        return false;
      }
      final receipt = toMap(data['message']);
      if (data['status'] == 'generated' &&
          _uuid(receipt['message_id']) != null &&
          receipt['conversation_id'] == id &&
          receipt['sequence_no'] == sequence + 1 &&
          receipt['role'] == 'assistant') {
        return true;
      }
      throw const FormatException('Invalid moderation generation receipt');
    },
  );
}
