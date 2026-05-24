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
      'page_size': size,
    };
    if (priority != null) query['priority'] = priority;
    return _client.requestPaged<V2ModerationContentItem>(
      ApiPaths.moderationContent,
      query: query,
      decodeItem: (item) => V2ModerationContentItem.fromJson(toMap(item)),
    );
  }

  Future<void> resolveContent({
    required int caseId,
    required String action,
    String? note,
  }) async {
    await _client.request<void>(
      '${ApiPaths.moderationContent}/$caseId/actions',
      method: 'POST',
      data: {'action': action, if (note != null) 'note': note},
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
        'post_ids': caseIds,
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
    final query = <String, dynamic>{'page': page, 'page_size': size};
    if (status != null) query['status'] = status;
    if (priority != null) query['priority'] = priority;
    return _client.requestPaged<V2ModerationReport>(
      ApiPaths.moderationReports,
      query: query,
      decodeItem: (item) => V2ModerationReport.fromJson(toMap(item)),
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
    final query = <String, dynamic>{'page': page, 'page_size': size};
    if (status != null) query['status'] = status;
    if (keyword != null) query['keyword'] = keyword;
    return _client.requestPaged<V2ModerationUserItem>(
      ApiPaths.moderationUsers,
      query: query,
      decodeItem: (item) => V2ModerationUserItem.fromJson(toMap(item)),
    );
  }

  Future<void> restrictUser({
    required int userId,
    required String action,
    String? reason,
    int? durationHours,
    String? note,
  }) async {
    await _client.request<void>(
      '${ApiPaths.moderationUsers}/$userId/actions',
      method: 'POST',
      data: {
        'action': action,
        if (reason != null) 'reason': reason,
        if (durationHours != null) 'duration_hours': durationHours,
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
    final query = <String, dynamic>{'page': page, 'page_size': size};
    if (status != null) query['status'] = status;
    return _client.requestPaged<V2ModerationAppeal>(
      ApiPaths.moderationAppeals,
      query: query,
      decodeItem: (item) => V2ModerationAppeal.fromJson(toMap(item)),
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
      data: {'status': status, if (response != null) 'response': response},
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
    return _client.requestList<V2ModerationSetting>(
      ApiPaths.moderationSettings,
      decodeItem: (item) => V2ModerationSetting.fromJson(toMap(item)),
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
