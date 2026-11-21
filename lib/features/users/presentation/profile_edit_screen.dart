import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';
import '../data/users_repository.dart';

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _displayName = TextEditingController();
  final _bio = TextEditingController();
  final _location = TextEditingController();
  final _website = TextEditingController();
  final _phone = TextEditingController();
  final _birthDate = TextEditingController();
  late final UsersRepository _repository;
  late final bool Function() _ownsSession;
  late final VoidCallback _unsubscribeSession;
  V2SelfUser? _user;
  bool _loading = true;
  bool _saving = false;
  bool _uploadingAvatar = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(usersRepositoryProvider);
    final tokens = ref.read(tokenStoreProvider);
    final revision = tokens.revision;
    final openedDuringChange = tokens.isSessionChanging;
    _ownsSession = () =>
        mounted &&
        !openedDuringChange &&
        identical(ref.read(usersRepositoryProvider), _repository) &&
        identical(ref.read(tokenStoreProvider), tokens) &&
        tokens.revision == revision &&
        !tokens.isSessionChanging;
    _unsubscribeSession = tokens.listenSessionChanges(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _unsubscribeSession();
    _displayName.dispose();
    _bio.dispose();
    _location.dispose();
    _website.dispose();
    _phone.dispose();
    _birthDate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_ownsSession()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = await _repository.getCurrentUser();
      if (!_ownsSession()) return;
      if (user.userId <= 0) throw const FormatException('Invalid profile');
      setState(() {
        _user = user;
        _displayName.text = user.displayName;
        _bio.text = user.bio;
        _location.text = user.location;
        _website.text = user.website;
        _phone.text = user.phone;
        _birthDate.text = user.birthDate?.split('T').first ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!_ownsSession()) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final owner = _user;
    if (_saving || owner == null || !_ownsSession()) return;
    final birthDate = _birthDate.text.trim();
    if (birthDate.isNotEmpty && !_validBirthDate(birthDate)) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('profile.birth_date_invalid'))),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final user = await _repository.updateProfile(
        displayName: _displayName.text.trim(),
        bio: _bio.text.trim(),
        location: _location.text.trim(),
        website: _website.text.trim(),
        phone: _phone.text.trim(),
        birthDate: birthDate,
      );
      if (!_ownsSession()) return;
      if (user.userId != owner.userId) {
        throw const FormatException('Invalid profile update response');
      }
      final l10n = AppLocalizations.of(context);
      setState(() => _user = user);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('profile.saved'))));
    } catch (e) {
      if (!_ownsSession()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_ownsSession()) setState(() => _saving = false);
    }
  }

  bool _validBirthDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final date = DateTime.tryParse('${value}T00:00:00Z');
    return date != null &&
        date.year > 0 &&
        date.toIso8601String().startsWith('${value}T');
  }

  Future<void> _changeAvatar() async {
    if (_uploadingAvatar || !_ownsSession()) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (!_ownsSession() || result == null || result.files.isEmpty) return;

    setState(() => _uploadingAvatar = true);
    try {
      final file = result.files.single;
      V2SelfUser user;
      if (file.bytes != null) {
        user = await _repository.changeAvatarBytes(
          bytes: file.bytes!,
          fileName: file.name,
        );
      } else if (file.path != null) {
        user = await _repository.changeAvatarFile(File(file.path!));
      } else {
        throw Exception('avatar file is empty');
      }
      if (!_ownsSession()) return;
      final l10n = AppLocalizations.of(context);
      setState(() => _user = user);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('profile.avatar_updated'))));
    } catch (e) {
      if (!_ownsSession()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (_ownsSession()) setState(() => _uploadingAvatar = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(usersRepositoryProvider);
    ref.watch(tokenStoreProvider);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ownsSession = _ownsSession();
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('settings.account.edit_profile')),
        actions: [
          TextButton(
            onPressed: !ownsSession || _saving || _user == null ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.t('common.save')),
          ),
        ],
      ),
      body: !ownsSession
          ? Center(child: Text(l10n.t('profile.session_changed')))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            AppAvatar(url: _user?.avatarUrl, size: 72),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: IconButton.filledTonal(
                                onPressed: _uploadingAvatar
                                    ? null
                                    : _changeAvatar,
                                tooltip: l10n.t('profile.change_avatar'),
                                icon: _uploadingAvatar
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.photo_camera_outlined,
                                        size: 18,
                                      ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _user?.displayName.isEmpty ?? true
                                    ? (_user?.username ?? '')
                                    : _user!.displayName,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '@${_user?.username ?? ''}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _displayName,
                      decoration: InputDecoration(
                        labelText: l10n.t('profile.display_name'),
                        prefixIcon: const Icon(Icons.badge_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _bio,
                      minLines: 3,
                      maxLines: 6,
                      decoration: InputDecoration(
                        labelText: l10n.t('profile.bio'),
                        alignLabelWithHint: true,
                        prefixIcon: const Padding(
                          padding: EdgeInsets.only(bottom: 60),
                          child: Icon(Icons.notes_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _location,
                      decoration: InputDecoration(
                        labelText: l10n.t('profile.location'),
                        prefixIcon: const Icon(Icons.place_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _website,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: l10n.t('profile.website'),
                        prefixIcon: const Icon(Icons.link),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('profile-phone'),
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: l10n.t('profile.phone'),
                        prefixIcon: const Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('profile-birth-date'),
                      controller: _birthDate,
                      keyboardType: TextInputType.datetime,
                      decoration: InputDecoration(
                        labelText: l10n.t('profile.birth_date'),
                        hintText: 'YYYY-MM-DD',
                        prefixIcon: const Icon(Icons.calendar_today_outlined),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined),
                        label: Text(l10n.t('common.save')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
