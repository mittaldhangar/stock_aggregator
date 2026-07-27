// Basic smoke test for StockAggregatorApp
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  testWidgets('Smoke test - App runs', (WidgetTester tester) async {
    await tester.pumpWidget(const StockAggregatorApp());
    expect(find.byType(StockAggregatorApp), findsOneWidget);
  });
}
