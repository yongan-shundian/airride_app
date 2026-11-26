import 'package:flutter_test/flutter_test.dart';
import 'package:airride_app/main.dart';

void main() {
  testWidgets('AirRide app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AirRideApp());
    expect(find.text('AirRide'), findsOneWidget);
  });
}