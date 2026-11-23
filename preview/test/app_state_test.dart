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

      state.setLibraryImageIdsIncluded(
        {'a2', 'b2'},
        included: true,
        onlyThese: true,
      );

      expect(state.includedLibraryImages.map((image) => image.id), [
        'a2',
        'b2',
      ]);

      state.setLibraryImageIdsIncluded({'a1', 'b1'}, included: true);
      expect(state.includedLibraryImages.map((image) => image.id), [
        'a1',
        'a2',
        'b1',
        'b2',
      ]);

      state.setLibraryImageIdsIncluded({'b1', 'b2', 'b3'}, included: false);
      expect(state.includedLibraryImages.map((image) => image.id), [
        'a1',
        'a2',
      ]);
    });

    test('images can be added to a comment and classified by file name', () {
      final state = AppState();
      state.addLibrarySource(
        LibrarySource(
          id: 'vtv',
          kind: LibrarySourceKind.vtv,
          label: 'g1/1',
          origin: r'C:\viscotech\task',
          groups: const [
            LibraryGroup(
              id: 'scratch',
              label: 'g1/1 / 傷',
              images: [
                LibraryImage(
                  id: 's1',
                  name: 'a.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\a.png',
                  listComment: '傷',
                  listIndex: 1,
                ),
              ],
            ),
            LibraryGroup(
              id: 'stain',
              label: 'g1/1 / 汚れ',
              images: [
                LibraryImage(
                  id: 't1',
                  name: 'b.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\b.png',
                  listComment: '汚れ',
                  listIndex: 1,
                ),
              ],
            ),
          ],
        ),
      );

      final added = state.appendLibraryImages(
        sourceId: 'vtv',
        groupId: 'scratch',
        paths: [r'C:\img\a.png', r'C:\extra\closeup.png'],
      );
      expect(added, 1);
      final scratch = state.librarySources.single.groups.first;
      expect(scratch.images.map((image) => image.name), [
        'a.png',
        'closeup.png',
      ]);
      expect(scratch.images.last.listComment, '傷');
      expect(scratch.images.last.listIndex, 2);

      final classified = classifyPathsByFileName([
        r'C:\new\sample_傷.png',
        r'C:\new\汚れ_01.jpg',
        r'C:\new\other.png',
        r'C:\new\readme.txt',
      ], state.librarySources.single.groups);
      expect(classified.byGroupId['scratch'], [r'C:\new\sample_傷.png']);
      expect(classified.byGroupId['stain'], [r'C:\new\汚れ_01.jpg']);
      expect(classified.unmatched, [r'C:\new\other.png']);
    });

    test('a folder is classified by words in the file names', () {
      final groups = groupsByFilename(
        sourceId: 'folder',
        paths: [
          r'C:\shots\sample_傷.png',
          r'C:\shots\02_傷.png',
          r'C:\shots\汚れ_01.jpg',
          r'C:\shots\other.png',
          r'C:\shots\closeup_a.png',
          r'C:\shots\closeup_b.png',
        ],
      );
      expect(groups, isNotNull);
      expect(groups!.map((group) => group.label), ['closeup', '傷', '汚れ', 'その他']);
      final scratch = groups.firstWhere((group) => group.label == '傷');
      expect(scratch.images.map((image) => image.name), ['02_傷.png', 'sample_傷.png']);
      expect(scratch.images.map((image) => image.listIndex), [1, 2]);
      expect(scratch.images.first.listComment, '傷');
      expect(groups.last.images.single.name, 'other.png');
      expect(groups.last.images.single.listComment, isNull);

      expect(
        groupsByFilename(sourceId: 'plain', paths: [r'C:\shots\IMG_0001.png', r'C:\shots\IMG_0002.png']),
        isNull,
      );
    });

    test('a classification can be added and removed', () {
      final state = AppState();
      state.addLibrarySource(
        LibrarySource(
          id: 'folder',
          kind: LibrarySourceKind.folder,
          label: 'shots',
          origin: r'C:\shots',
          groups: const [
            LibraryGroup(
              id: 'scratch',
              label: '傷',
              images: [
                LibraryImage(
                  id: 's1',
                  name: 'a.png',
                  sourceId: 'folder',
                  filePath: r'C:\shots\a.png',
                  listComment: '傷',
                  listIndex: 1,
                ),
              ],
            ),
          ],
        ),
      );

      expect(state.addLibraryGroup(sourceId: 'folder', name: '  '), '分類名を入力してください');
      expect(state.addLibraryGroup(sourceId: 'folder', name: '傷'), '同じ名前の分類があります');
      expect(state.addLibraryGroup(sourceId: 'folder', name: '汚れ'), isNull);
      final added = state.librarySources.single.groups[1];
      expect(added.label, '汚れ');
      expect(added.images, isEmpty);
      expect(commentToken(added), '汚れ');
      expect(
        imagesForGroup(
          sourceId: 'folder',
          group: added,
          paths: [r'C:\shots\b.png'],
          existingPaths: {'c:/shots/a.png'},
        ).single.listComment,
        '汚れ',
      );

      expect(state.removeLibraryGroup(sourceId: 'folder', groupId: 'scratch'), 1);
      final groups = state.librarySources.single.groups;
      expect(groups.map((group) => group.label), ['汚れ', 'その他']);
      expect(groups.last.images.single.id, 's1');
      expect(groups.last.images.single.listComment, isNull);
      expect(state.removeLibraryGroup(sourceId: 'folder', groupId: groups.last.id), -1);
    });

    test('filename classifications move images into the named groups', () {
      final state = AppState();
      state.addLibrarySource(
        LibrarySource(
          id: 'vtv',
          kind: LibrarySourceKind.vtv,
          label: 'g1/1',
          origin: r'C:\viscotech\task',
          groups: const [
            LibraryGroup(
              id: 'scratch',
              label: 'g1/1 / 傷',
              images: [
                LibraryImage(
                  id: 's1',
                  name: 'a.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\a.png',
                  listComment: '傷',
                  listIndex: 1,
                ),
                LibraryImage(
                  id: 's2',
                  name: 'stain_left.jpg',
                  sourceId: 'vtv',
                  filePath: r'C:\img\stain_left.jpg',
                  listComment: '傷',
                  listIndex: 2,
                ),
                LibraryImage(
                  id: 's3',
                  name: 'overview.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\overview.png',
                  listComment: '傷',
                  listIndex: 3,
                ),
              ],
            ),
            LibraryGroup(
              id: 'stain',
              label: 'g1/1 / 汚れ',
              images: [
                LibraryImage(
                  id: 't1',
                  name: 'c.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\c.png',
                  listComment: '汚れ',
                  listIndex: 1,
                ),
              ],
            ),
            LibraryGroup(id: 'other', label: 'その他', images: []),
          ],
        ),
      );

      final moved = state.reclassifyLibrary(
        sourceId: 'vtv',
        categoryByName: {
          'a.png': '傷',
          'stain_left.jpg': '汚れ',
          'overview.png': 'その他',
          'margin.png': '欠け',
        },
      );
      expect(moved, 2);
      final groups = state.librarySources.single.groups;
      expect(groups[0].images.map((image) => image.id), ['s1']);
      expect(groups[1].images.map((image) => image.name), ['c.png', 'stain_left.jpg']);
      expect(groups[1].images.last.listComment, '汚れ');
      expect(groups[1].images.last.listIndex, 2);
      expect(groups[2].images.single.name, 'overview.png');
      expect(groups[2].images.single.listComment, isNull);
    });

    test('an image can be moved into another classification', () {
      final state = AppState();
      state.addLibrarySource(
        LibrarySource(
          id: 'vtv',
          kind: LibrarySourceKind.vtv,
          label: 'g1/1',
          origin: r'C:\viscotech\task',
          groups: const [
            LibraryGroup(
              id: 'scratch',
              label: 'g1/1 / 傷',
              images: [
                LibraryImage(
                  id: 's1',
                  name: 'a.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\a.png',
                  listComment: '傷',
                  listIndex: 1,
                ),
                LibraryImage(
                  id: 's2',
                  name: 'b.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\b.png',
                  listComment: '傷',
                  listIndex: 2,
                ),
              ],
            ),
            LibraryGroup(
              id: 'stain',
              label: 'g1/1 / 汚れ',
              images: [
                LibraryImage(
                  id: 't1',
                  name: 'c.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\c.png',
                  listComment: '汚れ',
                  listIndex: 1,
                ),
              ],
            ),
            LibraryGroup(
              id: 'other',
              label: 'その他',
              images: [],
            ),
          ],
        ),
      );

      state.moveLibraryImage(imageId: 's2', sourceId: 'vtv', groupId: 'stain');
      final groups = state.librarySources.single.groups;
      expect(groups[0].images.map((image) => image.id), ['s1']);
      expect(groups[0].images.single.listIndex, 1);
      expect(groups[1].images.map((image) => image.id), ['t1', 's2']);
      expect(groups[1].images.last.listComment, '汚れ');
      expect(groups[1].images.last.listIndex, 2);

      state.moveLibraryImage(imageId: 's2', sourceId: 'vtv', groupId: 'other');
      final moved = state.librarySources.single.groups[2].images.single;
      expect(moved.id, 's2');
      expect(moved.listComment, isNull);
      expect(state.librarySources.single.groups[1].images.map((image) => image.id), ['t1']);
    });

    test('an image can be removed without dropping its comment group', () {
      final state = AppState();
      state.addLibrarySource(
        LibrarySource(
          id: 'vtv',
          kind: LibrarySourceKind.vtv,
          label: 'g1/1',
          origin: r'C:\viscotech\task',
          groups: const [
            LibraryGroup(
              id: 'scratch',
              label: '傷',
              images: [
                LibraryImage(
                  id: 's1',
                  name: 'a.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\a.png',
                ),
                LibraryImage(
                  id: 's2',
                  name: 'b.png',
                  sourceId: 'vtv',
                  filePath: r'C:\img\b.png',
                ),
              ],
            ),
          ],
        ),
      );
      state.addLibrarySource(
        LibrarySource(
          id: 'files',
          kind: LibrarySourceKind.files,
          label: 'files',
          origin: r'C:\img',
          groups: const [
            LibraryGroup(
              id: 'all',
              label: 'files',
              images: [
                LibraryImage(
                  id: 'f1',
                  name: 'c.png',
                  sourceId: 'files',
                  filePath: r'C:\img\c.png',
                ),
              ],
            ),
          ],
        ),
      );
      state.selectLibraryImage('s1');
      state.removeLibraryImage('s1');
      expect(state.selectedLibraryImageId, isNull);
      expect(
        state.librarySources.first.groups.single.images.map(
          (image) => image.id,
        ),
        ['s2'],
      );

      state.removeLibraryImage('s2');
      expect(state.librarySources.first.groups.single.images, isEmpty);

      state.removeLibraryImage('f1');
      expect(state.librarySources.map((source) => source.id), ['vtv']);

      state.setSlidePreset('slide-2', 'grid-2x2');
      expect(state.slidePreset('slide-1'), isNull);
      expect(state.slidePreset('slide-2'), 'grid-2x2');
      state.clearSlidePresets();
      expect(state.slidePreset('slide-2'), isNull);
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
