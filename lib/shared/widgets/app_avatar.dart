import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/providers.dart';
import '../theme/tokens.dart';

class AppAvatar extends ConsumerWidget {
  const AppAvatar({
    super.key,
    required this.url,
    this.size = 40,
    this.name,
    this.seed,
  });

  final String? url;
  final double size;
  final String? name;
  final int? seed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: _AvatarImage(url: url, size: size, name: name, seed: seed),
      ),
    );
  }
}

class _AvatarImage extends ConsumerWidget {
  const _AvatarImage({
    required this.url,
    required this.size,
    this.name,
    this.seed,
  });

  final String? url;
  final double size;
  final String? name;
  final int? seed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawUrl = url?.trim();
    if (rawUrl == null || rawUrl.isEmpty || _isPlaceholderAvatarUrl(rawUrl)) {
      return _AvatarFallback(size: size, name: name, seed: seed);
    }
    final resolver = ref.watch(assetUrlResolverProvider);
    final resolved = resolver.resolve(rawUrl);
    return CachedNetworkImage(
      imageUrl: resolved,
      fit: BoxFit.cover,
      placeholder: (context, _) =>
          _AvatarFallback(size: size, name: name, seed: seed),
      errorWidget: (context, _, __) =>
          _AvatarFallback(size: size, name: name, seed: seed),
    );
  }
}

bool _isPlaceholderAvatarUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.endsWith('/avatars/shadcn.jpg')) return true;
  return RegExp(
    r'/default-avatar\.(png|jpe?g|webp|svg|gif)(\?.*)?$',
  ).hasMatch(lower);
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.size, this.name, this.seed});

  final double size;
  final String? name;
  final int? seed;

  static const _lightTones = <Color>[
    Color(0xFFEDF0F4),
    Color(0xFFE9EFF8),
    Color(0xFFEDF2F7),
    Color(0xFFEAF0F6),
  ];

  static const _darkTones = <Color>[
    Color(0xFF1C2027),
    Color(0xFF1E2430),
    Color(0xFF1B222C),
    Color(0xFF20252E),
  ];

  int _toneIndex() {
    if (seed != null && seed! > 0) return seed!.abs() % _lightTones.length;
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      var hash = 0;
      for (final unit in trimmed.codeUnits) {
        hash = (hash * 31 + unit) & 0x7fffffff;
      }
      return hash % _lightTones.length;
    }
    return 0;
  }

  String? _initial() {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final clean = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
    if (clean.isEmpty) return null;
    final first = String.fromCharCode(clean.runes.first);
    return first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tones = isDark ? _darkTones : _lightTones;
    final bg = tones[_toneIndex()];
    final fg = theme.colorScheme.onSurface.withValues(alpha: 0.78);
    final initial = _initial();
    return ColoredBox(
      color: bg,
      child: Center(
        child: initial != null
            ? Text(
                initial,
                style: TextStyle(
                  color: fg,
                  fontSize: size * 0.40,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              )
            : Icon(
                Icons.pets_rounded,
                size: size * 0.44,
                color: fg.withValues(alpha: 0.72),
              ),
      ),
    );
  }
}

class AppMediaImage extends ConsumerWidget {
  const AppMediaImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
  });

  final String url;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolver = ref.watch(assetUrlResolverProvider);
    final resolved = resolver.resolve(url);
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.inner);
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: resolved,
        width: width,
        height: height,
        fit: fit,
        placeholder: (context, _) => Container(
          width: width,
          height: height,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
        errorWidget: (context, _, __) => Container(
          width: width,
          height: height,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }
}
