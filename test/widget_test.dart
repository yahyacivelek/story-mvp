import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:story/main.dart';

void main() {
  testWidgets('StoryApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: StoryApp()),
    );
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
