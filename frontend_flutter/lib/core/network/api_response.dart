class ApiMeta {
  const ApiMeta({
    this.page,
    this.pageSize,
    this.total,
    this.hasNext,
    this.limit,
  });

  final int? page;
  final int? pageSize;
  final int? total;
  final bool? hasNext;
  final int? limit;

  factory ApiMeta.fromJson(Map<String, dynamic> json) => ApiMeta(
    page: _toInt(json['page']),
    pageSize: _toInt(json['page_size']),
    total: _toInt(json['total']),
    hasNext: json['has_next'] as bool?,
    limit: _toInt(json['limit']),
  );

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

class ApiResponse<T> {
  const ApiResponse({
    required this.code,
    required this.message,
    required this.data,
    this.meta,
  });

  final int code;
  final String message;
  final T data;
  final ApiMeta? meta;
}

class PagedResult<T> {
  const PagedResult({required this.items, this.meta});

  final List<T> items;
  final ApiMeta? meta;

  bool get hasNext => meta?.hasNext ?? false;
  int get page => meta?.page ?? 1;
  int get pageSize => meta?.pageSize ?? items.length;
  int get total => meta?.total ?? items.length;
}
