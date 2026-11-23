import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/screens/expand_screen.dart';
import 'package:smart_report_preview/screens/master_slide_screen.dart';
import 'package:smart_report_preview/widgets/source_tray.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/state/app_state.dart';
import 'package:smart_report_preview/state/report_service.dart';

void main() {
  test('registered assets become the image list', () {
    final source = librarySourceFromProject(
      projectJson: '''
      {
        "assets": [
          {
            "path": "images/b.png",
            "fileName": "b.png",
            "listIndex": 2,
            "listComment": "拡大"
          },
          {
            "path": "C:/vtv/a.png",
            "fileName": "a.png",
            "listIndex": 1,
            "listComment": "全体"
          }
        ]
      }
      ''',
      projectDirectory: r'C:\work\report',
    );

    expect(source, isNotNull);
    expect(source!.imageCount, 2);
    expect(source.groups.map((group) => group.label), ['全体', '拡大']);
    expect(source.groups.first.images.single.filePath, r'C:\vtv\a.png');
    expect(
      source.groups.last.images.single.filePath,
      r'C:\work\report\images\b.png',
    );
  });

  testWidgets('the image list is still there after returning to the first slide', (tester) async {
    tester.view.physicalSize = const Size(2400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    state.setStep(WorkflowStep.master);
    state.addLibrarySource(
      LibrarySource(
        id: 'src-1',
        kind: LibrarySourceKind.files,
        label: 'VTV',
        origin: r'C:\viscotech\task',
        groups: const [
          LibraryGroup(
            id: 'g',
            label: '全体',
            images: [
              LibraryImage(
                id: 'img-1',
                name: 'photo.png',
                sourceId: 'src-1',
                filePath: r'C:\viscotech\task\photo.png',
              ),
            ],
          ),
        ],
      ),
    );
    final service = ReportService(state);

    await tester.pumpWidget(
      AppScope(
        state: state,
        service: service,
        child: const MaterialApp(
          home: Scaffold(
            body: _StepHost(),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('master:img-1')), findsOneWidget);

    state.setStep(WorkflowStep.expand);
    await tester.pump();
    expect(find.byKey(const Key('expand:img-1')), findsOneWidget);

    state.setStep(WorkflowStep.master);
    await tester.pump();
    expect(find.byKey(const Key('master:img-1')), findsOneWidget);
    expect(state.totalLibraryImages, 1);
  });

  testWidgets('the nth image of every comment can be used together', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    state.addLibrarySource(
      LibrarySource(
        id: 'vtv',
        kind: LibrarySourceKind.taskFile,
        label: 'VTV',
        origin: 'task.ziq',
        groups: const [
          LibraryGroup(
            id: 'comment-a',
            label: '傷A',
            images: [
              LibraryImage(id: 'a1', name: 'a1.png', sourceId: 'vtv'),
              LibraryImage(id: 'a2', name: 'a2.png', sourceId: 'vtv'),
            ],
          ),
          LibraryGroup(
            id: 'comment-b',
            label: '傷B',
            images: [
              LibraryImage(id: 'b1', name: 'b1.png', sourceId: 'vtv'),
              LibraryImage(id: 'b2', name: 'b2.png', sourceId: 'vtv'),
            ],
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      AppScope(
        state: state,
        service: ReportService(state),
        child: const MaterialApp(
          home: Scaffold(body: SourceTray(scope: 'master')),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('master-ordinal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2枚目').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('master-ordinal-only')));
    await tester.pump();

    expect(state.includedLibraryImages.map((image) => image.id), ['a2', 'b2']);

    await tester.tap(find.byKey(const Key('master-group:vtv:comment-a')));
    await tester.pump();
    expect(state.includedLibraryImages.map((image) => image.id), ['a1', 'a2', 'b2']);
  });
}

class _StepHost extends StatelessWidget {
  const _StepHost();

  @override
  Widget build(BuildContext context) {
    final step = AppScope.stateOf(context).step;
    return IndexedStack(
      index: step == WorkflowStep.expand ? 1 : 0,
      sizing: StackFit.expand,
      children: const [
        MasterSlideScreen(),
        ExpandScreen(),
      ],
    );
  }
}
