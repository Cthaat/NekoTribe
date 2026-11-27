import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/token_store.dart';
import '../../../core/config/app_config.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/viewport_visibility.dart';
import '../data/link_preview_api.dart';
import '../domain/link_preview.dart';

typedef _PreviewScope = ({
  TokenStore store,
  int revision,
  int endpoint,
  AppConfig config,
  bool enabled,
});
typedef _PreviewRequest = ({Uri url, _PreviewScope scope});

final linkPreviewApiProvider = Provider<LinkPreviewApi>(
  (ref) => LinkPreviewApi(ref.watch(apiClientProvider)),
);

final _previewScopeProvider = Provider.autoDispose<_PreviewScope>((ref) {
  final config = ref.watch(appConfigProvider);
  final store = ref.watch(tokenStoreProvider);
  final signedIn = ref.watch(
    authSessionProvider.select((s) => s.isAuthenticated),
  );
  final stop = store.listenSessionChanges(ref.invalidateSelf);
  ref.onDispose(stop);
  return (
    store: store,
    revision: store.revision,
    endpoint: store.endpointRevision,
    config: config,
    enabled: signedIn && !store.isSessionChanging,
  );
});

final _previewProvider = FutureProvider.autoDispose
    .family<V2LinkPreview?, _PreviewRequest>((ref, request) async {
      final scope = ref.watch(_previewScopeProvider);
      if (!scope.enabled || scope != request.scope) return null;
      final api = ref.watch(linkPreviewApiProvider);
      final cancel = CancelToken();
      ref.onDispose(cancel.cancel);
      try {
        final result = await api.read(request.url, cancelToken: cancel);
        if (cancel.isCancelled ||
            scope.store.isSessionChanging ||
            scope.store.revision != scope.revision ||
            scope.store.endpointRevision != scope.endpoint) {
          return null;
        }
        return result;
      } catch (_) {
        return null;
      }
    });

class ContentLinkPreview extends ConsumerStatefulWidget {
  const ContentLinkPreview({
    super.key,
    required this.content,
    this.markdown,
    this.onOpenLink,
  });

  final String content;
  final String? markdown;
  final Future<bool> Function(Uri)? onOpenLink;

  @override
  ConsumerState<ContentLinkPreview> createState() => _ContentLinkPreviewState();
}

class _ContentLinkPreviewState extends ConsumerState<ContentLinkPreview> {
  String? _lastSource;
  AppConfig? _lastConfig;
  _PreviewScope? _sourceScope;
  Uri? _candidate;

  @override
  void didUpdateWidget(covariant ContentLinkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.markdown ?? oldWidget.content) !=
        (widget.markdown ?? widget.content)) {
      _sourceScope = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.markdown ?? widget.content;
    if (!mayHaveLinkPreview(source) ||
        !ref.watch(authSessionProvider.select((s) => s.isAuthenticated))) {
      return const SizedBox.shrink();
    }
    final scope = ref.watch(_previewScopeProvider);
    if (!scope.enabled) return const SizedBox.shrink();
    // A still-mounted route can retain text from the previous login/backend.
    // Do not send that URL again until its content is replaced or remounted.
    _sourceScope ??= scope;
    if (_sourceScope != scope) return const SizedBox.shrink();
    if (_lastSource != source || !identical(_lastConfig, scope.config)) {
      _lastSource = source;
      _lastConfig = scope.config;
      final hosts =
          {
                Uri.tryParse(scope.config.apiBaseUrl)?.host,
                Uri.tryParse(scope.config.storageBaseUrl)?.host,
                if (kIsWeb) Uri.base.host,
              }
              .whereType<String>()
              .map((host) => host.replaceFirst(RegExp(r'\.$'), ''))
              .toSet();
      _candidate = firstPreviewUrl(source, excludedHosts: hosts);
    }
    final url = _candidate;
    if (url == null) return const SizedBox.shrink();
    final request = (url: url, scope: scope);
    return _DisplayedLinkPreview(
      key: ValueKey(request),
      request: request,
      onOpenLink: widget.onOpenLink,
    );
  }
}

class _DisplayedLinkPreview extends ConsumerStatefulWidget {
  const _DisplayedLinkPreview({
    super.key,
    required this.request,
    this.onOpenLink,
  });

  final _PreviewRequest request;
  final Future<bool> Function(Uri)? onOpenLink;

  @override
  ConsumerState<_DisplayedLinkPreview> createState() =>
      _DisplayedLinkPreviewState();
}

class _DisplayedLinkPreviewState extends ConsumerState<_DisplayedLinkPreview>
    with WidgetsBindingObserver {
  Set<ScrollPosition> _positions = {};
  bool _routeVisible = true;
  bool _queued = false;
  bool _displayed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeVisible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_displayed) return;
    final positions = {
      Scrollable.maybeOf(context, axis: Axis.vertical)?.position,
      Scrollable.maybeOf(context, axis: Axis.horizontal)?.position,
    }.whereType<ScrollPosition>().toSet();
    for (final position in _positions.difference(positions)) {
      position.removeListener(_checkNextFrame);
    }
    for (final position in positions.difference(_positions)) {
      position.addListener(_checkNextFrame);
    }
    _positions = positions;
    _checkNextFrame();
  }

  @override
  void didUpdateWidget(covariant _DisplayedLinkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _checkNextFrame();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _checkNextFrame();

  @override
  void didChangeMetrics() => _checkNextFrame();

  void _checkNextFrame() {
    if (_queued || _displayed || !_routeVisible) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          !_routeVisible ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
          !intersectsVisibleViewport(context)) {
        return;
      }
      _stopListeningToScroll();
      setState(() => _displayed = true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _stopListeningToScroll() {
    for (final position in _positions) {
      position.removeListener(_checkNextFrame);
    }
    _positions = {};
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToScroll();
    super.dispose();
  }

  Future<void> _open(Uri url) async {
    if (ref.read(_previewScopeProvider) != widget.request.scope) return;
    try {
      final open = widget.onOpenLink;
      if (open != null) {
        await open(url);
      } else {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // The platform may have no browser registered.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_displayed) return const SizedBox.square(dimension: 1);
    final preview = ref.watch(_previewProvider(widget.request)).asData?.value;
    if (preview == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final social = SocialColors.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(AppRadius.tile),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: social.surfaceSubtle,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            onTap: () => unawaited(_open(preview.url)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview.siteName.isEmpty
                        ? preview.url.host
                        : preview.siteName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (preview.title.isNotEmpty)
                    Text(
                      preview.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  if (preview.description.isNotEmpty)
                    Text(
                      preview.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
