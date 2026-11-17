import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/image_library_panel.dart';
import 'package:smart_report_preview/main.dart';

void main() {
  test('orders one reference list and keeps unnamed images after it', () {
    final groups = arrangeImageGroups(
      baseLabel: 'g01/01',
      names: ['b.bmp', 'a.bmp', 'c.jpg'],
      references: [
        const TaskReference(listName: 'cap', refs: ['a.bmp', 'c.jpg']),
      ],
    );

    expect(groups.single.label, 'g01/01');
    expect(groups.single.names, ['a.bmp', 'c.jpg', 'b.bmp']);
  });

  test('splits several reference lists and leaves the rest', () {
    final groups = arrangeImageGroups(
      baseLabel: 'g01/01',
      names: ['a.bmp', 'b.bmp', 'c.bmp'],
      references: [
        const TaskReference(listName: 'one', refs: ['b.bmp']),
        const TaskReference(listName: 'two', refs: ['a.bmp']),
      ],
    );

    expect(groups.map((group) => group.label), [
      'g01/01 / one',
      'g01/01 / two',
      'g01/01 / その他',
    ]);
    expect(groups[0].names, ['b.bmp']);
    expect(groups[1].names, ['a.bmp']);
    expect(groups[2].names, ['c.bmp']);
  });

  test('reads FILE= names from task text', () {
    final names = parseFileReferences('Comment=ng\nFILE=b.bmp\nFILE=a.bmp\n'.codeUnits);

    expect(names, ['b.bmp', 'a.bmp']);
  });

  test('shows the comment name and keeps every comment line', () {
    final parsed = parseTaskListText(
      'Comment=外観\nComment=端部\nFILE=a.bmp\nnote=ignored\n'.codeUnits,
      listName: 'cap',
    );
    expect(parsed.listComment, '外観 / 端部');
    expect(parsed.refs, ['a.bmp']);
    final groups = arrangeImageGroups(
      baseLabel: 'g01/03',
      names: ['a.bmp', 'b.bmp'],
      references: [parsed],
    );
    expect(groups.single.label, 'g01/03 / 外観 / 端部');
    expect(groups.single.listName, 'cap');
    expect(groups.single.names, ['a.bmp', 'b.bmp']);
  });

  test('labels a viscotech task image as group/task', () {
    expect(
      taskGroupLabel('viscotech/task/g01/03/img/a.bmp'),
      'g01/03',
    );
    expect(taskGroupLabel('notes/picture.png'), 'notes');
  });

  test('loads images from a folder and skips other files', () async {
    final root = await Directory.systemTemp.createTemp('library_folder_');
    addTearDown(() => root.delete(recursive: true));
    final nested = Directory(
      '${root.path}${Platform.pathSeparator}nested',
    )..createSync();
    await File('${root.path}${Platform.pathSeparator}a.png').writeAsBytes([1]);
    await File('${nested.path}${Platform.pathSeparator}b.jpg').writeAsBytes([
      1,
    ]);
    await File('${root.path}${Platform.pathSeparator}note.txt').writeAsString(
      'skip',
    );

    final source = await loadFolderImages(sourceId: 'folder', folderPath: root.path);

    expect(source.kind, LibrarySourceKind.folder);
    expect(source.imageCount, 2);
    expect(
      source.groups.map((group) => group.images.map((image) => image.name)),
      [
        ['a.png'],
        ['b.jpg'],
      ],
    );
  });

  test('loads VTV images from task/gXX/task/img', () async {
    final root = await Directory.systemTemp.createTemp('library_vtv_');
    addTearDown(() => root.delete(recursive: true));
    final separator = Platform.pathSeparator;
    final img = Directory(
      '${root.path}${separator}task${separator}g02${separator}15${separator}img',
    )..createSync(recursive: true);
    final other = Directory(
      '${root.path}${separator}task${separator}g01${separator}01${separator}img',
    )..createSync(recursive: true);
    await File('${img.path}${separator}z.bmp').writeAsBytes([1]);
    await File('${img.path}${separator}note.txt').writeAsString('FILE=z.bmp\n');
    await File('${other.path}${separator}other.bmp').writeAsBytes([1]);

    final source = await loadVtvImages(
      sourceId: 'vtv',
      root: root.path,
      groupNumber: '2',
      taskNumber: '15',
    );

    expect(source.origin, resolveVtvTaskRoot(root.path));
    expect(source.groups.single.label, 'g02/15');
    expect(source.groups.single.images.single.name, 'z.bmp');
    expect(source.groups.single.images.single.filePath, endsWith('z.bmp'));
  });

  test('lists task-file images in FILE= order and reads the bytes', () async {
    final root = await Directory.systemTemp.createTemp('library_task_');
    addTearDown(() => root.delete(recursive: true));
    final bmp = Uint8List.fromList([0x42, 0x4D, 1, 2, 3, 4]);
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes('viscotech/task/g01/03/img/a.bmp', bmp),
      )
      ..addFile(
        ArchiveFile.bytes('viscotech/task/g01/03/img/b.bmp', bmp),
      )
      ..addFile(
        ArchiveFile.bytes(
          'viscotech/task/g01/03/img/list.txt',
          'FILE=b.bmp\nFILE=a.bmp\n'.codeUnits,
        ),
      )
      ..addFile(
        ArchiveFile.bytes('viscotech/task/g02/01/img/c.bmp', bmp),
      );
    final zipPath = '${root.path}${Platform.pathSeparator}sample.ziq';
    await File(zipPath).writeAsBytes(ZipEncoder().encode(archive));

    final source = await loadTaskFileImages(
      sourceId: 'task',
      filePath: zipPath,
      groupNumber: '1',
      taskNumber: '03',
    );

    expect(source.kind, LibrarySourceKind.taskFile);
    expect(source.groups.single.label, 'g01/03');
    expect(
      source.groups.single.images.map((image) => image.name),
      ['b.bmp', 'a.bmp'],
    );
    final first = source.groups.single.images.first;
    expect(
      readZipEntryBytes(source.zipCatalog!, first.archiveEntry!),
      bmp,
    );
  });

  testWidgets('selects a listed image and assigns it', (tester) async {
    final source = LibrarySource(
      id: 's',
      kind: LibrarySourceKind.files,
      label: 'a.png',
      origin: 'a.png',
      groups: [
        LibraryGroup(
          id: 'g',
          label: 'a.png',
          images: const [
            LibraryImage(
              id: 'i',
              name: 'a.png',
              sourceId: 's',
              filePath: 'a.png',
            ),
          ],
        ),
      ],
    );
    String? selectedId;
    LibraryImage? assigned;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return ImageLibraryPanel(
                sources: [source],
                selectedImageId: selectedId,
                loading: false,
                message: null,
                canAssign: selectedId != null,
                onSelect: (image) => setState(() => selectedId = image.id),
                onAssign: (image) => assigned = image,
                onAddFolder: () {},
                onAddFiles: () {},
                onOpenDefaultVtv: () {},
                onPickVtv: () {},
                onAddTaskFile: () {},
                onRegisterList: () {},
                onRemoveSource: (_) {},
                onClear: () {},
                loadArchiveBytes: (_) async => Uint8List(0),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-add-folder')), findsOneWidget);
    expect(find.byKey(const Key('library-add-task')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('library-image-i')));
    await tester.tap(find.byKey(const Key('library-image-i')));
    await tester.pumpAndSettle();
    expect(selectedId, 'i');

    await tester.tap(find.byKey(const Key('library-assign')));
    await tester.pump();
    expect(assigned?.name, 'a.png');
  });

  testWidgets('places the image library beside the slide', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const PreviewApp(initialPath: 'missing-layout.json'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('image-library')), findsOneWidget);
    expect(find.byKey(const Key('layout-path')), findsOneWidget);
    expect(find.byKey(const Key('preview-pane')), findsOneWidget);
    expect(find.text('プロジェクト'), findsOneWidget);
    expect(find.text('配置を開くと、ここにスライドが出ます'), findsOneWidget);

    final library = tester.getTopLeft(find.byKey(const Key('image-library')));
    final preview = tester.getTopLeft(find.byKey(const Key('preview-pane')));
    expect(library.dx, lessThan(preview.dx));
    expect(preview.dy, greaterThan(tester.getTopLeft(find.text('プロジェクト')).dy));
  });
}
