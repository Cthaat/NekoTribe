import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/token_store.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../../posts/domain/post_models.dart';
import '../data/users_api.dart';

typedef ProfilePinState = ({V2Post? post, bool ready, bool busy});

final profilePinnedPostProvider = StateNotifierProvider.autoDispose
    .family<ProfilePinController, ProfilePinState, int>((ref, userId) {
      final api = ref.watch(usersApiProvider);
      final store = ref.watch(tokenStoreProvider);
      final signedIn = ref.watch(
        authSessionProvider.select((value) => value.isAuthenticated),
      );
      final stop = store.listenSessionChanges(ref.invalidateSelf);
      ref.onDispose(stop);
      return ProfilePinController(api, store, userId, signedIn);
    });

class ProfilePinController extends StateNotifier<ProfilePinState> {
  ProfilePinController(this._api, this._store, this._profileId, this._signedIn)
    : _revision = _store.revision,
      _endpoint = _store.endpointRevision,
      super((post: null, ready: false, busy: false)) {
    unawaited(_read());
  }

  final UsersApi _api;
  final TokenStore _store;
  final int _profileId;
  final bool _signedIn;
  final int _revision;
  final int _endpoint;
  final _deleted = <int>{};
  CancelToken? _request;

  bool get isCurrent =>
      mounted &&
      _signedIn &&
      !_store.isSessionChanging &&
      _store.revision == _revision &&
      _store.endpointRevision == _endpoint;

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    if (!isCurrent || _profileId < 1) return;
    final token = _request = CancelToken();
    try {
      final post = await _api.getPinnedPost(_profileId, cancelToken: token);
      if (!isCurrent) return;
      state = (
        post: _deleted.contains(post?.postId) ? null : post,
        ready: true,
        busy: false,
      );
    } catch (_) {
      // The ordinary profile timeline can load without a pin.
    } finally {
      if (isCurrent && identical(_request, token)) _request = null;
    }
  }

  Future<void> setPinned(V2Post post, {required bool pinned}) async {
    if (!isCurrent ||
        !state.ready ||
        _request != null ||
        post.author.userId != _profileId ||
        _deleted.contains(post.postId)) {
      return;
    }
    final current = state.post;
    final alreadyPinned = current?.postId == post.postId;
    if (alreadyPinned == pinned) return;
    final token = _request = CancelToken();
    state = (post: current, ready: true, busy: true);
    try {
      if (pinned) {
        await _api.setPinnedPost(post.postId, cancelToken: token);
      } else {
        await _api.clearPinnedPost(cancelToken: token);
      }
      if (isCurrent) {
        state = (
          post: pinned && !_deleted.contains(post.postId) ? post : null,
          ready: true,
          busy: false,
        );
      }
    } finally {
      if (isCurrent && identical(_request, token)) {
        _request = null;
        if (state.busy) state = (post: state.post, ready: true, busy: false);
      }
    }
  }

  void update(V2Post post) {
    if (isCurrent && state.post?.postId == post.postId) {
      state = (post: post, ready: state.ready, busy: state.busy);
    }
  }

  void remove(int postId) {
    if (!isCurrent) return;
    _deleted.add(postId);
    if (state.post?.postId == postId) {
      state = (post: null, ready: state.ready, busy: state.busy);
    }
  }
}

List<V2Post> profilePostsWithPin(List<V2Post> posts, V2Post? pinned) {
  if (pinned == null) return posts;
  return [pinned, ...posts.where((post) => post.postId != pinned.postId)];
}

List<V2Post> appendProfilePosts(List<V2Post> posts, List<V2Post> page) {
  final seen = posts.map((post) => post.postId).toSet();
  return [...posts, ...page.where((post) => seen.add(post.postId))];
}

Future<void> changeProfilePin(
  BuildContext context,
  ProfilePinController controller,
  V2Post post, {
  required bool pinned,
}) async {
  try {
    await controller.setPinned(post, pinned: pinned);
  } catch (error) {
    if (context.mounted && controller.isCurrent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, error))),
      );
    }
  }
}
