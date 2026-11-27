import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/constants/storage_keys.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/ai/data/ai_writing_api.dart';
import 'package:nekotribe/features/ai/presentation/ai_writing_screen.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';
import 'package:nekotribe/features/posts/presentation/post_detail_screen.dart';
import 'package:nekotribe/features/users/presentation/appearance_screen.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';
import 'package:nekotribe/shared/theme/app_theme.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_bars.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_shader.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_surface.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_tokens.dart';
import 'package:nekotribe/shared/widgets/ui/surface_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class _Posts extends PostsApi {
  _Posts(super.client);

  @override
  Future<V2Post> getPost(int postId) async => V2Post.fromJson({
    'post_id': postId,
    'content': 'A post under the glass',
    'author': {'user_id': 42, 'username': 'author'},
  });

  @override
  Future<PagedResult<V2Comment>> getComments(
    int postId, {
    int page = 1,
    int size = 20,
    String sort = 'newest',
  }) async => PagedResult(items: []);
}

class _Writing extends AiWritingApi {
  _Writing(super.client);

  @override
  Future<AiAvailability> availability() async =>
      const AiAvailability(knowledge: true, writing: true);

  @override
  Future<AiConversation> readConversation(String id) async =>
      AiConversation(id: id, purpose: 'writing', title: 'Draft', updatedAt: '');

  @override
  Future<List<AiWritingMessage>> listMessages(
    String id, {
    int afterSequence = 0,
    int? beforeSequence,
  }) async => const [
    AiWritingMessage(id: '1', role: 'user', content: 'Hello', sequence: 1),
  ];
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  final store = TokenStore();
  final client = ApiClient(config: _config, tokenStore: store);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appConfigBundleProvider.overrideWithValue(
          const AppConfigBundle(defaults: _config, presets: []),
        ),
        appConfigInitialProvider.overrideWithValue(_config),
        tokenStoreProvider.overrideWithValue(store),
        authSessionProvider.overrideWith((_) => AuthSessionController(store)),
        postsApiProvider.overrideWithValue(_Posts(client)),
        aiWritingApiProvider.overrideWithValue(_Writing(client)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [AppLocalizationsDelegate()],
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpDock(WidgetTester tester, List<int> changes, {bool reduced = false}) async {
  var selected = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          bottomNavigationBar: Center(
            heightFactor: 1,
            child: SizedBox(
              width: 358,
              child: StatefulBuilder(
                builder: (context, setState) => LiquidGlassNavDock(
                  items: List.generate(
                    5,
                    (i) => LiquidGlassNavItem(
                      label: 'Tab $i',
                      icon: Icons.circle_outlined,
                      selectedIcon: Icons.circle,
                    ),
                  ),
                  selectedIndex: selected,
                  onSelected: (i) {
                    changes.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'compiled fragment shader loads from the Flutter asset bundle',
    () async {
      final program = await ui.FragmentProgram.fromAsset(
        LiquidGlassShaderCache.asset,
      );
      final shader = program.fragmentShader();
      shader
        ..setFloat(2, 20)
        ..setFloat(3, 12)
        ..setFloat(4, 6)
        ..setFloat(5, 0.8)
        ..dispose();
    },
  );

  test('both intensity presets keep all volume tints below 0.70', () {
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      for (final intensity in LiquidGlassIntensity.values) {
        for (final preset in LiquidGlassPreset.values) {
          final spec = LiquidGlassSpec.resolve(
            preset,
            theme.colorScheme,
            intensity,
          );
          expect(
            spec.tintColor.a,
            lessThan(0.70),
            reason: '$preset $intensity',
          );
          expect(saturationColorMatrix(spec.saturation), hasLength(20));
        }
      }
    }
  });

  testWidgets(
    'nested pills retain the specular rim without a backdrop filter',
    (tester) async {
      for (final blurEnabled in [true, false]) {
        await _pump(
          tester,
          Scaffold(
            body: LiquidGlassSurface(
              preset: blurEnabled
                  ? LiquidGlassPreset.navDock
                  : LiquidGlassPreset.pillIndicator,
              borderRadius: BorderRadius.circular(24),
              blurEnabled: blurEnabled,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        );
        final surface = find.byType(LiquidGlassSurface);
        expect(
          find.descendant(of: surface, matching: find.byType(BackdropFilter)),
          blurEnabled ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(of: surface, matching: find.byType(CustomPaint)),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets(
    'appearance toggles the default and persists both intensity values',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pump(tester, const AppearanceScreen());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppearanceScreen)),
      );
      expect(
        container.read(themeProvider).glassIntensity,
        LiquidGlassIntensity.standard,
      );
      final prefs = await SharedPreferences.getInstance();
      for (final (label, intensity) in [
        ('Soft & subtle', LiquidGlassIntensity.subtle),
        ('Lively & clear', LiquidGlassIntensity.standard),
      ]) {
        final choice = find.text(label);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(container.read(themeProvider).glassIntensity, intensity);
        expect(
          prefs.getString(StorageKeys.liquidGlassIntensity),
          intensity.name,
        );
      }
    },
  );

  testWidgets('appearance restores and persists the compact mode switch', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await _pump(tester, const AppearanceScreen());

    final toggle = find.byType(Switch);
    bool isCompact() => tester.widget<Switch>(toggle).value;
    expect(isCompact(), isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(isCompact(), isTrue);

    final prefs = await SharedPreferences.getInstance();
    const key = 'nekotribe.compact_mode';
    expect(prefs.getBool(key), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, const AppearanceScreen());
    expect(isCompact(), isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(isCompact(), isFalse);
    expect(prefs.getBool(key), isFalse);
  });

  testWidgets(
    'post replies and AI messages scroll behind their input islands',
    (tester) async {
      for (final (screen, scrollType) in [
        (const PostDetailScreen(postId: 1), CustomScrollView),
        (const AiWritingScreen(initialConversationId: 'draft'), ListView),
      ]) {
        await _pump(tester, screen);
        final island = find.byWidgetPredicate(
          (widget) =>
              widget is LiquidGlassSurface &&
              widget.preset == LiquidGlassPreset.floatingIsland,
        );
        final scroll = find.byType(scrollType);
        expect(island, findsOneWidget);
        expect(scroll, findsOneWidget);
        final overlay = find
            .ancestor(of: island, matching: find.byType(Stack))
            .first;
        expect(find.descendant(of: overlay, matching: scroll), findsOneWidget);
        expect(tester.getRect(scroll).overlaps(tester.getRect(island)), isTrue);
        expect(
          tester
              .widgetList<Scaffold>(find.byType(Scaffold))
              .first
              .extendBodyBehindAppBar,
          isTrue,
        );
      }
    },
  );

  testWidgets(
    'LiquidGlassNavDock encloses active icon and label in full-height pill',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var selected = 0;
      await _pump(
        tester,
        Scaffold(
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: StatefulBuilder(
              builder: (context, setState) => LiquidGlassNavDock(
                selectedIndex: selected,
                onSelected: (idx) => setState(() => selected = idx),
                items: const [
                  LiquidGlassNavItem(
                    icon: Icons.home_outlined,
                    selectedIcon: Icons.home_rounded,
                    label: '首页',
                  ),
                  LiquidGlassNavItem(
                    icon: Icons.groups_outlined,
                    selectedIcon: Icons.groups_rounded,
                    label: '群组',
                  ),
                  LiquidGlassNavItem(
                    icon: Icons.notifications_outlined,
                    selectedIcon: Icons.notifications_rounded,
                    label: '通知',
                    badgeCount: 5,
                  ),
                  LiquidGlassNavItem(
                    icon: Icons.chat_bubble_outline_rounded,
                    selectedIcon: Icons.chat_bubble_rounded,
                    label: '消息',
                  ),
                  LiquidGlassNavItem(
                    icon: Icons.person_outline_rounded,
                    selectedIcon: Icons.person_rounded,
                    label: '我的',
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final dock = find.byType(LiquidGlassNavDock);
      expect(dock, findsOneWidget);
      final pill = find.byWidgetPredicate(
        (w) =>
            w is LiquidGlassSurface &&
            w.preset == LiquidGlassPreset.pillIndicator,
      );
      expect(pill, findsOneWidget);
      final pillRect = tester.getRect(pill);
      final homeIconRect = tester.getRect(find.byIcon(Icons.home_rounded));
      final homeLabelRect = tester.getRect(find.text('首页'));
      expect(pillRect.contains(homeIconRect.center), isTrue);
      expect(pillRect.contains(homeLabelRect.center), isTrue);
      expect(pillRect.height, greaterThanOrEqualTo(50));
      expect(find.text('5'), findsOneWidget);

      await tester.tap(find.text('群组'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      final updatedPillRect = tester.getRect(pill);
      expect(
        updatedPillRect.contains(
          tester.getRect(find.byIcon(Icons.groups_rounded)).center,
        ),
        isTrue,
      );
      expect(updatedPillRect.contains(tester.getRect(find.text('群组')).center), isTrue);
    },
  );

  testWidgets('dock follows a scrub and recenters after either edge or cancellation', (
    tester,
  ) async {
    final selected = <int>[];
    await _pumpDock(tester, selected);
    final pill = find.byWidgetPredicate(
      (w) => w is LiquidGlassSurface && w.preset == LiquidGlassPreset.pillIndicator,
    );
    Offset center(int i) => tester.getCenter(find.text('Tab $i'));
    final width = center(1).dx - center(0).dx;
    double position() => (tester.getCenter(pill).dx - center(0).dx) / width;
    expect(tester.getSize(find.byType(LiquidGlassNavDock)).height, 62);
    expect(tester.getSize(pill).height, 54);

    for (final (start, end, sign) in [(0, 4, 1), (4, 0, -1)]) {
      final gesture = await tester.startGesture(center(start));
      await gesture.moveTo(center(2));
      await tester.pump();
      expect(position(), closeTo(2, 0.005));
      expect(selected.length, start == 0 ? 0 : 1);
      await gesture.moveTo(center(end) + Offset(sign * width * 2, 0));
      await tester.pump();
      expect((position() - end) * sign, inInclusiveRange(0.20, 0.22001));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected.last, end);
      expect((tester.getCenter(pill).dx - center(end).dx).abs(), lessThan(0.5));
    }
    final cancelled = await tester.startGesture(center(0));
    await tester.pump(const Duration(milliseconds: 600));
    await cancelled.moveTo(center(2));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(selected, [4, 0]);
    expect(position(), closeTo(0, 0.005));
    await tester.flingFrom(center(0), Offset(width, 0), width * 12);
    await tester.pumpAndSettle();
    expect(selected.last, 2);
    expect(position(), closeTo(2, 0.005));
  });

  testWidgets('long press scrubs and reduced motion aligns immediately', (tester) async {
    final selected = <int>[];
    for (final reduced in [false, true]) {
      await _pumpDock(tester, selected, reduced: reduced);
      final pill = find.byWidgetPredicate(
        (w) => w is LiquidGlassSurface && w.preset == LiquidGlassPreset.pillIndicator,
      );
      final dest = tester.getCenter(find.text('Tab 3'));
      final hold = await tester.startGesture(tester.getCenter(find.text('Tab 1')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(tester.widget<LiquidGlassSurface>(pill).lensProgress, reduced ? 0 : 1);
      await hold.moveTo(dest + const Offset(10, 0));
      await tester.pump();
      expect(tester.getCenter(pill).dx, closeTo(dest.dx + 10, 0.5));
      await hold.up();
      await tester.pump();
      expect(selected.last, 3);
      if (reduced) expect(tester.getCenter(pill).dx, closeTo(dest.dx, 0.5));
      await tester.pumpAndSettle();
      expect(tester.getCenter(pill).dx, closeTo(dest.dx, 0.5));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected.last, 0);
  });

  testWidgets('LiquidGlassIconButton uses iconButton preset and handles taps', (
    tester,
  ) async {
    var tapped = 0;
    await _pump(
      tester,
      Scaffold(
        body: Center(
          child: LiquidGlassIconButton(
            key: const Key('glass-action'),
            tooltip: 'Search',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => tapped++,
          ),
        ),
      ),
    );
    final button = find.byKey(const Key('glass-action'));
    expect(button, findsOneWidget);
    expect(
      find.descendant(
        of: button,
        matching: find.byWidgetPredicate(
          (w) =>
              w is LiquidGlassSurface &&
              w.preset == LiquidGlassPreset.iconButton,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  test('dark theme resolves default and legacy blue to Sky Blue #8CC8FF', () {
    for (final seed in [const Color(0xFF007AFF), const Color(0xFF2563EB)]) {
      final dark = AppTheme.dark(seed);
      expect(dark.colorScheme.primary, const Color(0xFF8CC8FF));
      expect(dark.colorScheme.onPrimary, const Color(0xFF081829));
      final light = AppTheme.light(seed);
      expect(light.colorScheme.primary, const Color(0xFF007AFF));
      expect(light.colorScheme.onPrimary, Colors.white);
      expect(
        dark.textTheme.bodyMedium?.fontFamilyFallback,
        containsAll(['Microsoft YaHei UI', 'PingFang SC', 'Noto Sans SC']),
      );
    }
  });

  testWidgets('SurfaceCard stays glass-free in content layer', (tester) async {
    await _pump(
      tester,
      const Scaffold(
        body: SurfaceCard(child: Text('Bento content')),
      ),
    );
    final card = find.byType(SurfaceCard);
    expect(
      find.descendant(of: card, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.byType(LiquidGlassSurface)),
      findsNothing,
    );
  });
}
