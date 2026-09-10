import '../../../core/constants/api_paths.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_response.dart';
import '../../../core/utils/json_utils.dart';
import '../domain/notification_models.dart';

class NotificationsApi {
  NotificationsApi(this._client);

  final ApiClient _client;

  Future<PagedResult<V2Notification>> list({
    int page = 1,
    int size = 20,
    String? type,
    bool? unreadOnly,
  }) {
    final query = <String, dynamic>{'page': page, 'page_size': size};
    if (type != null) query['type'] = type;
    if (unreadOnly != null) query['unread_only'] = unreadOnly;
    return _client.requestPaged<V2Notification>(
      ApiPaths.notifications,
      query: query,
      decodeItem: (item) => V2Notification.fromJson(toMap(item)),
    );
  }

  Future<int> unreadCount() {
    return _client.requestData<int>(
      ApiPaths.notificationsReadStatus,
      decode: (data) {
        final map = toMap(data);
        return toInt(map['unread_count']) ?? 0;
      },
    );
  }

  Future<void> markRead(List<int> ids) async {
    await _client.request<void>(
      ApiPaths.notificationsReadStatus,
      method: 'PUT',
      data: {'notification_ids': ids},
      decode: (_) {},
    );
  }

  Future<void> setReadStatus({
    required int notificationId,
    required bool isRead,
  }) async {
    await _client.request<void>(
      '${ApiPaths.notifications}/$notificationId/read-status',
      method: 'PUT',
      data: {'is_read': isRead},
      decode: (_) {},
    );
  }

  Future<void> markAllRead() async {
    await _client.request<void>(
      ApiPaths.notificationsReadStatus,
      method: 'PUT',
      data: {'mark_all': true},
      decode: (_) {},
    );
  }

  Future<void> deleteNotification(int id) async {
    await _client.request<void>(
      '${ApiPaths.notifications}/$id',
      method: 'DELETE',
      decode: (_) {},
    );
  }

  Future<void> restoreNotification(int id) async {
    await _client.request<void>(
      '${ApiPaths.notifications}/$id/restore-status',
      method: 'PUT',
      decode: (_) {},
    );
  }
}
