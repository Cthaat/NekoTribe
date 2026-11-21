import 'dart:convert';

import '../config/app_config.dart';
import '../storage/asset_url_resolver.dart';
import 'endpoint_probe_native.dart'
    if (dart.library.js_interop) 'endpoint_probe_web.dart';

enum EndpointReadiness { ready, unavailable, unsupported, unreachable }

typedef EndpointChecks = ({EndpointReadiness api, EndpointReadiness media});

Future<EndpointChecks> probeDeploymentEndpoints(AppConfig config) async {
  final api = probeEndpointReadiness(config.apiBaseUrl);
  final mediaUrl = AssetUrlResolver(
    config,
  ).resolve(AssetUrlResolver.defaultAvatarPath);
  final media = _probeMedia(Uri.parse(mediaUrl));
  return (api: await api, media: await media);
}

Future<EndpointReadiness> probeEndpointReadiness(String address) async {
  final base = AppConfig.fromCustom(apiBaseUrl: address).apiBaseUrl;
  final url = Uri.parse('$base/api/ready');
  try {
    final response = await requestEndpointProbe(
      url,
      const Duration(seconds: 5),
      4096,
    );
    return classifyEndpointReadiness(response.status, response.body);
  } catch (_) {
    return EndpointReadiness.unreachable;
  }
}

Future<EndpointReadiness> _probeMedia(Uri url) async {
  try {
    final response = await requestEndpointProbe(
      url,
      const Duration(seconds: 5),
      0,
      head: true,
    );
    return classifyMediaReadiness(
      response.status,
      response.contentType,
      response.contentLength,
    );
  } catch (_) {
    return EndpointReadiness.unreachable;
  }
}

EndpointReadiness classifyMediaReadiness(
  int status,
  String? contentType,
  String? contentLength,
) {
  if (status == 503) return EndpointReadiness.unavailable;
  if (status == 404 || status == 405) return EndpointReadiness.unsupported;
  if (status != 200) return EndpointReadiness.unreachable;
  final mime = contentType?.split(';').first.trim().toLowerCase();
  final length = int.tryParse(contentLength ?? '', radix: 10);
  return mime == 'image/png' && length != null && length > 0
      ? EndpointReadiness.ready
      : EndpointReadiness.unsupported;
}

EndpointReadiness classifyEndpointReadiness(int status, List<int> body) {
  if (status == 404 || status == 405) return EndpointReadiness.unsupported;
  if (status != 200 && status != 503) return EndpointReadiness.unreachable;
  try {
    final result = jsonDecode(utf8.decode(body));
    if (result is Map) {
      if (status == 200 && result['status'] == 'ready') {
        return EndpointReadiness.ready;
      }
      if (status == 503 && result['status'] == 'unavailable') {
        return EndpointReadiness.unavailable;
      }
    }
  } on FormatException {
    // A frontend or older proxy can return HTML with 200 for unknown paths.
  }
  return EndpointReadiness.unsupported;
}
