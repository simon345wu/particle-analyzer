import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:particle_analyzer_app/main.dart';

void main() {
  testWidgets('Dashboard basic UI test', (WidgetTester tester) async {
    // Set a larger desktop screen size to prevent layout overflows.
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Build our app under ProviderScope and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(),
      ),
    );

    // Verify that the application title is present.
    expect(find.text('咖啡粉顆粒大小分析器'), findsAtLeastNWidgets(1));
    expect(find.text('參數即時調校控制台'), findsOneWidget);
    expect(find.text('載入合成測試影像'), findsOneWidget);
    expect(find.text('從相簿選擇'), findsOneWidget);
    expect(find.text('開啟相機'), findsOneWidget);

    // Tap the language toggle button ("EN")
    await tester.tap(find.text('EN'));
    await tester.pumpAndSettle();

    // Verify UI has changed to English
    expect(find.text('Coffee Particle Analyzer'), findsAtLeastNWidgets(1));
    expect(find.text('Real-time Controls'), findsOneWidget);
    expect(find.text('Load Test Image'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
  });
}
