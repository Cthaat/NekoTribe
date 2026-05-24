import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nekotribe/shared/window/desktop_window_frame.dart';

void main() {
  testWidgets('desktop frame provides drag and window controls', (tester) async {
    final controls = _FakeWindowControls();

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopWindowFrame(
          enabled: true,
          controls: controls,
          child: const Text('app body'),
        ),
      ),
    );

    expect(find.text('app body'), findsOneWidget);
    expect(find.byKey(desktopWindowMinimizeButtonKey), findsOneWidget);
    expect(find.byKey(desktopWindowMaximizeButtonKey), findsOneWidget);
    expect(find.byKey(desktopWindowCloseButtonKey), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(desktopWindowDragAreaKey)),
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    expect(controls.dragStarts, 1);

    await tester.tap(find.byKey(desktopWindowMinimizeButtonKey));
    await tester.tap(find.byKey(desktopWindowMaximizeButtonKey));
    await tester.tap(find.byKey(desktopWindowCloseButtonKey));
    await tester.pump();

    expect(controls.minimizes, 1);
    expect(controls.maximizes, 1);
    expect(controls.closes, 1);
  });

  testWidgets('desktop frame can be disabled', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopWindowFrame(enabled: false, child: Text('app body')),
      ),
    );

    expect(find.text('app body'), findsOneWidget);
    expect(find.byKey(desktopWindowMinimizeButtonKey), findsNothing);
    expect(find.byKey(desktopWindowMaximizeButtonKey), findsNothing);
    expect(find.byKey(desktopWindowCloseButtonKey), findsNothing);
  });
}

class _FakeWindowControls implements WindowControls {
  int dragStarts = 0;
  int minimizes = 0;
  int maximizes = 0;
  int closes = 0;
  bool maximized = false;

  @override
  Future<void> startDragging() async {
    dragStarts++;
  }

  @override
  Future<void> minimize() async {
    minimizes++;
  }

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> maximize() async {
    maximizes++;
    maximized = true;
  }

  @override
  Future<void> unmaximize() async {
    maximized = false;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}
