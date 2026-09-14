import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picklist_tracker/ui/screens/crash_recovery_screen.dart';

void main() {
  testWidgets('CrashRecoveryScreen displays error message and countdown', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CrashRecoveryScreen(
          errorMessage: 'Simulated Fatal UI Exception',
          stackTrace: '#0 simulated_stack_trace',
        ),
      ),
    );

    // Initial render checks
    expect(find.text('Application Error'), findsOneWidget);
    expect(find.textContaining('Closing in 10 s...'), findsOneWidget);
    expect(find.text('Close Now'), findsOneWidget);
    expect(find.text('View Diagnostics'), findsOneWidget);

    // Advance timer by 1 second
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Closing in 9 s...'), findsOneWidget);

    // Toggle diagnostics
    await tester.tap(find.text('View Diagnostics'));
    await tester.pump();
    expect(find.textContaining('Simulated Fatal UI Exception'), findsOneWidget);
  });
}
