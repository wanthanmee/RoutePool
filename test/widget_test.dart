import 'package:flutter_test/flutter_test.dart';

import 'package:routepool/main.dart';

void main() {
  testWidgets('App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const RoutePoolApp());
    expect(find.byType(RoutePoolApp), findsOneWidget);
  });
}
