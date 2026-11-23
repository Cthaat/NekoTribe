import 'package:dio/dio.dart';

import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/post_draft.dart';

typedef PostDraftPage = ({List<V2PostDraft> items, int? cursor});

class PostDraftsApi {
  PostDraftsApi(this._client);

  final ApiClient _client;

  Future<PostDraftPage> list({
    int? groupId,
    int? beforeId,
    required CancelToken cancel,
  }) => _client.requestData<PostDraftPage>(
    ApiPaths.usersMeDrafts,
    query: {
      if (groupId != null) 'group_id': groupId,
      if (beforeId != null) 'before_id': beforeId,
    },
    cancelToken: cancel,
    decode: (raw) {
      final data = toMap(raw);
      final entries = data['items'];
      final cursor = data['next_before_id'];
      if (entries is! List ||
          (cursor != null && !V2PostDraft.validId(cursor))) {
        throw const FormatException('Invalid draft page');
      }
      final items = entries
          .map((row) => V2PostDraft.fromJson(toMap(row)))
          .toList();
      var previousId = beforeId;
      for (final draft in items) {
        if ((previousId != null && draft.id >= previousId) ||
            (groupId != null && (draft.payload.groupId ?? 0) != groupId)) {
          throw const FormatException('Invalid draft page scope');
        }
        previousId = draft.id;
      }
      if (cursor != null && (items.isEmpty || cursor != items.last.id)) {
        throw const FormatException('Invalid draft page cursor');
      }
      return (items: items, cursor: cursor as int?);
    },
  );

  Future<V2PostDraft> save(
    V2PostDraftInput input, {
    int? id,
    required CancelToken cancel,
  }) => _write(
    id: id,
    method: id == null ? 'POST' : 'PUT',
    input: input.toJson(),
    groupId: input.groupId,
    status: PostDraftStatus.draft,
    cancel: cancel,
  );

  Future<V2PostDraft> schedule(
    V2PostDraft draft,
    DateTime at, {
    required CancelToken cancel,
  }) => _write(
    id: draft.id,
    suffix: '/schedule',
    method: 'PUT',
    input: {'scheduled_at': at.toUtc().toIso8601String()},
    groupId: draft.payload.groupId,
    status: PostDraftStatus.scheduled,
    cancel: cancel,
  );

  Future<V2PostDraft> unschedule(
    V2PostDraft draft, {
    required CancelToken cancel,
  }) => _write(
    id: draft.id,
    suffix: '/schedule',
    method: 'DELETE',
    groupId: draft.payload.groupId,
    status: PostDraftStatus.draft,
    cancel: cancel,
  );

  Future<V2PostDraft> publish(
    V2PostDraft draft, {
    required CancelToken cancel,
  }) => _write(
    id: draft.id,
    suffix: '/publish',
    method: 'POST',
    groupId: draft.payload.groupId,
    status: PostDraftStatus.published,
    cancel: cancel,
  );

  Future<void> remove(int id, {required CancelToken cancel}) async {
    await _client.request<void>(
      '${ApiPaths.usersMeDrafts}/$id',
      method: 'DELETE',
      cancelToken: cancel,
      decode: (data) {
        if (data != null) {
          throw const FormatException('Invalid draft delete receipt');
        }
      },
    );
  }

  Future<V2PostDraft> _write({
    int? id,
    String suffix = '',
    required String method,
    Map<String, Object?>? input,
    required int? groupId,
    required PostDraftStatus status,
    required CancelToken cancel,
  }) => _client.requestData<V2PostDraft>(
    '${ApiPaths.usersMeDrafts}${id == null ? '' : '/$id'}$suffix',
    method: method,
    data: input,
    cancelToken: cancel,
    decode: (data) {
      final draft = V2PostDraft.fromJson(toMap(data));
      if ((id != null && draft.id != id) ||
          draft.status != status ||
          draft.payload.groupId != groupId) {
        throw const FormatException('Invalid post draft receipt');
      }
      return draft;
    },
  );
}
