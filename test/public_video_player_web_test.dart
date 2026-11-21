@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/features/media/presentation/public_video_player_web.dart';

void main() {
  testWidgets('browser mounts the video platform view only while expanded', (
    tester,
  ) async {
    final url = Uri.base.resolve('/storage/movie.mp4');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublicVideoPlayer(url: url, label: 'movie.mp4'),
        ),
      ),
    );
    expect(find.byType(HtmlElementView), findsNothing);

    await tester.tap(find.text('展开视频播放器'));
    await tester.pumpAndSettle();
    final view = tester.widget<HtmlElementView>(find.byType(HtmlElementView));
    expect(view.creationParams, containsPair('tagName', 'video'));
    expect(view.onPlatformViewCreated, isNotNull);

    await tester.tap(find.text('收起视频播放器'));
    await tester.pumpAndSettle();
    expect(find.byType(HtmlElementView), findsNothing);
  });
}
