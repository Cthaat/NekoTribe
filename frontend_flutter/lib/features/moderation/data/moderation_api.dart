import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/moderation_models.dart';

class ModerationApi {
  ModerationApi(this._client);

  final ApiClient _client;

  Future<V2ModerationStats> stats() {
    return _client.requestData<V2ModerationStats>(
      ApiPaths.moderationStats,
      decode: (data) => V2ModerationStats.fromJson(toMap(data)),
    );
  }

  Future<PagedResult<V2ModerationContentItem>> content({
    String status = 'pending',
    String? priority,
    int page = 1,
    int size = 20,
  }) {
    final query = <String, dynamic>{
      'status': status,
      'page': page,
      'size': size,
    };
    if (priority != null) query['priority'] = priority;
    return _client.requestData<PagedResult<V2ModerationContentItem>>(
      ApiPaths.moderationContent,
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2ModerationContentItem.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2ModerationContentItem>(items: items, meta: meta);
      },
    );
  }

  Future<void> resolveContent({
    required int caseId,
    required String action,
    String? note,
  }) async {
    await _client.request<void>(
      '${ApiPaths.moderationContent}/$caseId',
      method: 'PATCH',
      data: {
        'action': action,
        if (note != null) 'note': note,
      },
      decode: (_) {},
    );
  }

  Future<void> bulkAction({
    required List<int> caseIds,
    required String action,
    String? note,
  }) async {
    await _client.request<void>(
      ApiPaths.moderationContentBulkActions,
      method: 'POST',
      data: {
        'case_ids': caseIds,
        'action': action,
        if (note != null) 'note': note,
      },
      decode: (_) {},
    );
  }

  Future<PagedResult<V2ModerationReport>> reports({
    String? status,
    String? priority,
    int page = 1,
    int size = 20,
  }) {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
    };
    if (status != null) query['status'] = status;
    if (priority != null) query['priority'] = priority;
    return _client.requestData<PagedResult<V2ModerationReport>>(
      ApiPaths.moderationReports,
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2ModerationReport.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2ModerationReport>(items: items, meta: meta);
      },
    );
  }

  Future<void> updateReport({
    required int reportId,
    required String status,
    String? resolutionNote,
  }) async {
    await _client.request<void>(
      '${ApiPaths.moderationReports}/$reportId',
      method: 'PATCH',
      data: {
        'status': status,
        if (resolutionNote != null) 'resolution_note': resolutionNote,
      },
      decode: (_) {},
    );
  }

  Future<PagedResult<V2ModerationUserItem>> users({
    String? status,
    int page = 1,
    int size = 20,
    String? keyword,
  }) {
    final query = <String, dynamic>{'page': page, 'size': size};
    if (status != null) query['status'] = status;
    if (keyword != null) query['keyword'] = keyword;
    return _client.requestData<PagedResult<V2ModerationUserItem>>(
      ApiPaths.moderationUsers,
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2ModerationUserItem.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2ModerationUserItem>(items: items, meta: meta);
      },
    );
  }

  Future<void> restrictUser({
    required int userId,
    required String action,
    String? until,
    String? note,
  }) async {
    await _client.request<void>(
      '${ApiPaths.moderationUsers}/$userId/restrictions',
      method: 'POST',
      data: {
        'action': action,
        if (until != null) 'until': until,
        if (note != null) 'note': note,
      },
      decode: (_) {},
    );
  }

  Future<PagedResult<V2ModerationAppeal>> appeals({
    String? status,
    int page = 1,
    int size = 20,
  }) {
    final query = <String, dynamic>{'page': page, 'size': size};
    if (status != null) query['status'] = status;
    return _client.requestData<PagedResult<V2ModerationAppeal>>(
      ApiPaths.moderationAppeals,
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2ModerationAppeal.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2ModerationAppeal>(items: items, meta: meta);
      },
    );
  }

  Future<void> updateAppeal({
    required int appealId,
    required String status,
    String? response,
  }) async {
    await _client.request<void>(
      '${ApiPaths.moderationAppeals}/$appealId',
      method: 'PATCH',
      data: {
        'status': status,
        if (response != null) 'response': response,
      },
      decode: (_) {},
    );
  }

  Future<V2ModerationAppeal> submitAppeal({
    required int statementId,
    required String message,
  }) {
    return _client.requestData<V2ModerationAppeal>(
      '${ApiPaths.usersMeStatements}/$statementId/appeals',
      method: 'POST',
      data: {'message': message},
      decode: (data) => V2ModerationAppeal.fromJson(toMap(data)),
    );
  }

  Future<List<V2ModerationSetting>> settings() {
    return _client.requestData<List<V2ModerationSetting>>(
      ApiPaths.moderationSettings,
      decode: (data) {
        final map = toMap(data);
        return toList(
          map['items'],
          (e) => V2ModerationSetting.fromJson(toMap(e)),
        );
      },
    );
  }

  Future<void> updateSettings(Map<String, dynamic> body) async {
    await _client.request<void>(
      ApiPaths.moderationSettings,
      method: 'PATCH',
      data: body,
      decode: (_) {},
    );
  }
}
