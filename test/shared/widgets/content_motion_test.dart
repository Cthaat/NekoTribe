import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/features/chat/presentation/chat_message_extras.dart';
import 'package:nekotribe/shared/motion/entrance.dart';
import 'package:nekotribe/shared/motion/skeleton.dart';
import 'package:nekotribe/shared/theme/app_theme.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_surface.dart';
import 'package:nekotribe/shared/widgets/glass/liquid_glass_tokens.dart';
import 'package:nekotribe/shared/widgets/ui/surface_card.dart';

void main() {
  testWidgets('recycled first-screen rows do not replay their entrance', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(home: ListView.builder(
      controller: scroll, itemCount: 100, itemExtent: 100,
      itemBuilder: (_, i) => StaggeredEntrance(index: i, child: Text('row $i')),
    )));
    Finder rowSlide() => find.descendant(of: find.byType(StaggeredEntrance).first,
      matching: find.byType(SlideTransition));
    expect(rowSlide(), findsOneWidget);
    scroll.jumpTo(4000);
    await tester.pump();
    scroll.jumpTo(0);
    await tester.pump();
    expect(rowSlide(), findsNothing);
  });

  testWidgets('skeleton dissolves over content and stale content leaves immediately', (tester) async {
    Future<void> show(bool loading) => tester.pumpWidget(MaterialApp(
      home: SkeletonCrossFade(
        loading: loading,
        child: Text(loading ? 'skeleton' : 'content'),
      ),
    ));
    await show(true);
    await show(false);
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('skeleton'), findsOneWidget);
    final fade = find.ancestor(of: find.text('skeleton'), matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, closeTo(.5, .05));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('skeleton'), findsNothing);
    await show(true);
    expect(find.text('content'), findsNothing);
  });

  testWidgets('content and chat actions follow appearance and accessibility preferences', (tester) async {
    for (final width in [390.0, 1200.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      for (final dark in [false, true]) {
        for (final intensity in LiquidGlassIntensity.values) {
          for (final reduced in [false, true]) {
            for (final contrast in [false, true]) {
              var invoked = false;
              await tester.pumpWidget(MaterialApp(
                key: UniqueKey(),
                theme: (dark ? AppTheme.dark : AppTheme.light)(Colors.blue, intensity),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: reduced, highContrast: contrast),
                  child: child!,
                ),
                home: Scaffold(body: Column(children: [
                  const ShimmerBox(width: 96, height: 16),
                  SurfaceCard(onTap: () {}, child: ChatMessageMotion(
                    actions: [(icon: Icons.reply, label: 'Reply', run: () => invoked = true)],
                    child: const Text('Message'),
                  )),
                ])),
              ));
              await tester.pump();
              final shimmer = tester.widget<Container>(find.descendant(
                of: find.byType(ShimmerBox), matching: find.byType(Container)));
              expect((shimmer.decoration! as BoxDecoration).gradient,
                reduced ? isNull : isA<LinearGradient>());
              expect(find.byType(LiquidGlassSurface), findsNothing);
              await tester.longPress(find.text('Message'));
              await tester.pump(const Duration(milliseconds: 250));
              expect(find.byType(LiquidGlassSurface), findsOneWidget);
              await tester.tap(find.byTooltip('Reply'));
              await tester.pump();
              expect(invoked, isTrue);
            }
          }
        }
      }
    }
    await tester.binding.setSurfaceSize(null);
  });
}
