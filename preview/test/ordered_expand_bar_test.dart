import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/ordered_expand_bar.dart';

void main() {
  test('uses candidate ordinals when the server reports no extra slides', () {
    expect(
      missingSlides(reported: 0, existingSlides: 1, candidateOrdinals: [0, 1, 2]),
      2,
    );
    expect(
      missingSlides(reported: 4, existingSlides: 1, candidateOrdinals: [0]),
      4,
    );
    expect(
      missingSlides(reported: 0, existingSlides: 3, candidateOrdinals: [0, 1]),
      0,
    );
  });

  testWidgets('shows add and keep buttons only when slides are short', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderedExpandBar(
            slidesToAdd: 4,
            canExpand: true,
            canAccept: true,
            saving: false,
            onExpand: () {},
            onAcceptAdding: () {},
            onAcceptExisting: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('ordered-expand')), findsOneWidget);
    expect(find.text('スライドが4枚足りません'), findsOneWidget);
    expect(find.byKey(const Key('ordered-accept-new')), findsOneWidget);
    expect(find.byKey(const Key('ordered-accept-existing')), findsOneWidget);
    expect(find.byKey(const Key('ordered-accept-all')), findsNothing);
    expect(find.byKey(const Key('ordered-create-slides')), findsNothing);
  });

  testWidgets('shows a single accept button when every slide already exists', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderedExpandBar(
            slidesToAdd: 0,
            canExpand: true,
            canAccept: true,
            saving: false,
            onExpand: () {},
            onAcceptAdding: () {},
            onAcceptExisting: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('ordered-accept-all')), findsOneWidget);
    expect(find.byKey(const Key('ordered-accept-new')), findsNothing);
    expect(find.textContaining('足りません'), findsNothing);
  });
}