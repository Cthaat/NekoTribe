import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../data/auth_repository.dart';
import '../domain/github_oauth_models.dart';

final gitHubAuthorizationLauncherProvider =
    Provider<Future<bool> Function(Uri)>(
      (ref) =>
          (url) => launchUrl(
            url,
            mode: LaunchMode.externalApplication,
            webOnlyWindowName: '_blank',
          ),
    );

String gitHubOAuthError(BuildContext context, Object error) {
  final status = error is ApiException ? error.statusCode : null;
  return AppLocalizations.of(context).t(switch (status) {
    401 => 'github_oauth.authorization_failed',
    403 => 'error.forbidden',
    404 => 'error.not_found',
    409 => 'github_oauth.conflict',
    503 => 'github_oauth.unavailable',
    _ => 'error.generic',
  });
}

Future<T?> showGitHubOAuth<T>({
  required BuildContext context,
  required AuthRepository repository,
  required bool Function() isCurrent,
  required bool signIn,
  required Future<T?> Function(GitHubOAuthFlow, CancelToken) poll,
}) => showDialog<T>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _GitHubOAuthDialog<T>(
    repository: repository,
    isCurrent: isCurrent,
    signIn: signIn,
    poll: poll,
  ),
);

class _GitHubOAuthDialog<T> extends ConsumerStatefulWidget {
  const _GitHubOAuthDialog({
    required this.repository,
    required this.isCurrent,
    required this.signIn,
    required this.poll,
  });

  final AuthRepository repository;
  final bool Function() isCurrent;
  final bool signIn;
  final Future<T?> Function(GitHubOAuthFlow, CancelToken) poll;

  @override
  ConsumerState<_GitHubOAuthDialog<T>> createState() =>
      _GitHubOAuthDialogState<T>();
}

class _GitHubOAuthDialogState<T> extends ConsumerState<_GitHubOAuthDialog<T>> {
  final _cancelToken = CancelToken();
  late final VoidCallback _stopObserving;
  Timer? _expiry;
  Timer? _nextPoll;
  GitHubOAuthFlow? _flow;
  String? _error;
  bool _launching = false;
  bool _waiting = false;
  bool _closed = false;

  bool get _active =>
      mounted && !_cancelToken.isCancelled && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _stopObserving = widget.repository.listenSessionChanges(_scopeChanged);
    unawaited(_begin());
  }

  Future<void> _begin() async {
    if (!_active) return;
    // Start the local deadline before the request to account for its latency.
    _expiry = Timer(GitHubOAuthFlow.duration, () {
      if (_active) {
        _fail(AppLocalizations.of(context).t('github_oauth.expired'));
      }
    });
    try {
      final flow = await widget.repository.beginGitHubOAuth(
        signIn: widget.signIn,
        cancelToken: _cancelToken,
      );
      if (_active) setState(() => _flow = flow);
    } catch (error) {
      if (_active) _fail(gitHubOAuthError(context, error));
    }
  }

  void _scopeChanged() {
    if (!mounted || _closed || _cancelToken.isCancelled || widget.isCurrent()) {
      return;
    }
    _stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) _close();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _open() async {
    final flow = _flow;
    if (!_active || _launching || flow == null) return;
    setState(() {
      _launching = true;
      _error = null;
    });
    var opened = false;
    try {
      // This is reached directly from the button tap, including on Web.
      opened = await ref.read(gitHubAuthorizationLauncherProvider)(
        flow.authorizationUrl,
      );
    } catch (_) {
      // A failed launcher leaves the current flow available for another tap.
    }
    if (!_active) return;
    final wasWaiting = _waiting;
    setState(() {
      _launching = false;
      _waiting = _waiting || opened;
      if (!opened) {
        _error = AppLocalizations.of(context).t('github_oauth.open_failed');
      }
    });
    if (opened && !wasWaiting) unawaited(_poll(flow));
  }

  Future<void> _poll(GitHubOAuthFlow flow) async {
    if (!_active) return;
    try {
      final receipt = await widget.poll(flow, _cancelToken);
      if (!_active) return;
      if (receipt != null) {
        _close(receipt);
        return;
      }
      _nextPoll = Timer(const Duration(seconds: 2), () => _poll(flow));
    } catch (error) {
      if (_active) _fail(gitHubOAuthError(context, error));
    }
  }

  void _stop() {
    _expiry?.cancel();
    _nextPoll?.cancel();
    if (!_cancelToken.isCancelled) _cancelToken.cancel();
    _flow = null;
  }

  void _fail(String description) {
    _stop();
    setState(() => _error = description);
  }

  void _close([T? result]) {
    if (_closed) return;
    _closed = true;
    _stop();
    final route = ModalRoute.of<T>(context);
    final navigator = route?.navigator;
    if (route?.isCurrent == true) {
      navigator?.pop(result);
    } else if (route?.isActive == true) {
      navigator?.removeRoute(route!, result);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _stopObserving();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authRepositoryProvider, (_, _) => _scopeChanged());
    final l10n = AppLocalizations.of(context);
    final flow = _flow;
    final dialog = AlertDialog(
      title: Text(
        l10n.t(widget.signIn ? 'github_oauth.sign_in' : 'github_oauth.link'),
      ),
      content: _error != null
          ? Text(_error!)
          : flow == null
          ? const LinearProgressIndicator()
          : Text(
              l10n.t(
                _waiting ? 'github_oauth.waiting' : 'github_oauth.open_hint',
              ),
            ),
      actions: [
        TextButton(onPressed: _close, child: Text(l10n.t('common.cancel'))),
        if (flow != null)
          FilledButton(
            onPressed: _launching ? null : _open,
            child: Text(l10n.t('github_oauth.open')),
          ),
      ],
    );
    return PopScope<T>(
      onPopInvokedWithResult: (popped, _) {
        if (popped) {
          _closed = true;
          _stop();
        }
      },
      child: dialog,
    );
  }
}
