import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/state/app_state.dart';

void main() {
  group('AppState', () {
    test('starts at the start step with no open project', () {
      final state = AppState();
      expect(state.step, WorkflowStep.start);
      expect(state.hasOpenProject, isFalse);
      expect(state.slideCount, 1);
      expect(state.busy, isFalse);
      expect(state.errorMessage, isNull);
      expect(state.currentPreset, 'horizontal-2');
    });

    test('setProject + updateDocuments marks the project as open', () {
      final state = AppState();
      var changes = 0;
      state.addListener(() => changes += 1);

      state.setProject(
        directory: '/tmp/demo',
        projectPath: '/tmp/demo/project.json',
        layoutPath: '/tmp/demo/layout.json',
        pptxPath: '/tmp/demo/report.pptx',
      );
      // layout を未設定でも開いたとは見なさないことを確認する。
      expect(state.hasOpenProject, isFalse);

      state.updateDocuments(
        projectJson: '{"slides":[{"id":"slide-1"},{"id":"slide-2"}]}',
      );
      expect(state.slideCount, 2);
      expect(changes, greaterThan(1));
    });

    test('closeProject resets step and clears identity', () {
      final state = AppState();
      state.setProject(
        directory: '/tmp/demo',
        projectPath: '/tmp/demo/project.json',
        layoutPath: '/tmp/demo/layout.json',
        pptxPath: '/tmp/demo/report.pptx',
      );
      state.setStep(WorkflowStep.expand);

      state.closeProject();

      expect(state.step, WorkflowStep.start);
      expect(state.projectPath, isNull);
      expect(state.slideCount, 1);
    });

    test('the same position in every comment can be chosen together', () {
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
                LibraryImage(id: 'b3', name: 'b3.png', sourceId: 'vtv'),
              ],
            ),
          ],
        ),
      );

      state.setLibraryImageIdsIncluded({'a2', 'b2'}, included: true, onlyThese: true);

      expect(
        state.includedLibraryImages.map((image) => image.id),
        ['a2', 'b2'],
      );

      state.setLibraryImageIdsIncluded({'a1', 'b1'}, included: true);
      expect(
        state.includedLibraryImages.map((image) => image.id),
        ['a1', 'a2', 'b1', 'b2'],
      );

      state.setLibraryImageIdsIncluded({'b1', 'b2', 'b3'}, included: false);
      expect(
        state.includedLibraryImages.map((image) => image.id),
        ['a1', 'a2'],
      );
    });

    test('setBusy propagates status and clears the previous error', () {
      final state = AppState();
      state.setError('oops');
      expect(state.errorMessage, 'oops');

      state.setBusy(true, status: '処理中');

      expect(state.busy, isTrue);
      expect(state.statusMessage, '処理中');
      expect(state.errorMessage, isNull);
    });
  });
}
