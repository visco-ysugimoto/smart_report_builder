import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';
import 'package:smart_report_preview/state/report_service.dart';
import 'package:smart_report_preview/widgets/step_header.dart';

LayoutResult _emptyLayout() => const LayoutResult(
      schemaVersion: 1,
      slideWidthPt: 720,
      slideHeightPt: 540,
      elements: [],
      violations: [],
      skippedElementIds: [],
      previewMode: 'content',
    );

void main() {
  Widget buildHeader(AppState state) {
    final service = ReportService(state);
    return MaterialApp(
      home: Scaffold(
        body: AppScope(
          state: state,
          service: service,
          child: const StepHeader(),
        ),
      ),
    );
  }

  Future<void> pumpAtDesktopSize(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildHeader(state));
  }

  testWidgets('renders all three step labels', (tester) async {
    final state = AppState();
    await pumpAtDesktopSize(tester, state);

    expect(find.text('開始・ソース登録'), findsOneWidget);
    expect(find.text('1枚目を型として編集'), findsOneWidget);
    expect(find.text('展開して個別調整'), findsOneWidget);
  });

  testWidgets('hides save button until a project is open', (tester) async {
    final state = AppState();
    await pumpAtDesktopSize(tester, state);
    expect(find.byKey(const Key('header-save')), findsNothing);

    state.setProject(
      directory: '/tmp/demo',
      projectPath: '/tmp/demo/project.json',
      layoutPath: '/tmp/demo/layout.json',
      pptxPath: '/tmp/demo/report.pptx',
    );
    state.updateDocuments(
      layout: _emptyLayout(),
      projectJson: '{"slides":[{"id":"slide-1"}]}',
    );
    state.setStep(WorkflowStep.master);
    await tester.pump();

    expect(find.byKey(const Key('header-save')), findsOneWidget);
    expect(find.byKey(const Key('header-close-project')), findsOneWidget);
  });
}
