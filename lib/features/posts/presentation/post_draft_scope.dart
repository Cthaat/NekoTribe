import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/token_store.dart';
import '../../../shared/providers/providers.dart';
import '../data/post_drafts_api.dart';
import '../domain/post_draft.dart';

typedef ScopedPostDraft = ({V2PostDraft draft, PostDraftScope scope});

class PostDraftScope {
  PostDraftScope(WidgetRef ref)
    : store = ref.read(tokenStoreProvider),
      api = ref.read(postDraftsApiProvider),
      _revision = ref.read(tokenStoreProvider).revision,
      _endpoint = ref.read(tokenStoreProvider).endpointRevision;

  final TokenStore store;
  final PostDraftsApi api;
  final int _revision;
  final int _endpoint;

  bool isCurrent(WidgetRef ref) =>
      ref.read(authSessionProvider).isAuthenticated &&
      identical(ref.read(tokenStoreProvider), store) &&
      !store.isSessionChanging &&
      store.revision == _revision &&
      store.endpointRevision == _endpoint &&
      identical(ref.read(postDraftsApiProvider), api);
}
