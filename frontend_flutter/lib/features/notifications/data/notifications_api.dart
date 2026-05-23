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
    final query = <String, dynamic>{
      'page': page,
      'size': size,
    };
    if (type != null) query['type'] = type;
    if (unreadOnly != null) query['unread_only'] = unreadOnly;
    return _client.requestData<PagedResult<V2Notification>>(
      ApiPaths.notifications,
      query: query,
      decode: (data) {
        final map = toMap(data);
        final items = toList(
          map['items'],
          (e) => V2Notification.fromJson(toMap(e)),
        );
        final meta = map['meta'] is Map<String, dynamic>
            ? ApiMeta.fromJson(map['meta'] as Map<String, dynamic>)
            : null;
        return PagedResult<V2Notification>(items: items, meta: meta);
      },
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
}
