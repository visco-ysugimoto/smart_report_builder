import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/note_geometry.dart';
import 'package:smart_report_preview/slide_preview.dart';

void main() {
  test('a right click hits the frontmost roi, table, or image', () {
    final result = LayoutResult(
      schemaVersion: 1,
      slideWidthPt: 960,
      slideHeightPt: 540,
      violations: const [],
      skippedElementIds: const [],
      previewMode: 'blank',
      elements: [
        _frame(fitMode: 'contain', roleId: 'overall'),
        PlacedElement(
          elementId: 'roi-1',
          kind: 'roi',
          roleId: 'roi',
          displayName: 'ROI',
          frame: const SlideRect(x: 2, y: 2, width: 4, height: 4),
          contentRect: null,
          text: null,
          assetPath: null,
          fitMode: 'roi',
          crop: null,
        ),
        PlacedElement(
          elementId: 'table-1',
          kind: 'table',
          roleId: 'table',
          displayName: '表',
          frame: const SlideRect(x: 12, y: 0, width: 6, height: 6),
          contentRect: null,
          text: null,
          assetPath: null,
          fitMode: 'table',
          crop: null,
        ),
      ],
    );
    expect(previewHitAt(result, 3, 3)?.elementId, 'roi-1');
    expect(previewHitAt(result, 8, 8)?.elementId, 'frame');
    expect(previewHitAt(result, 14, 2)?.elementId, 'table-1');
    expect(previewHitAt(result, 20, 20), isNull);
  });

  test('image frame kind follows the zoom fit and the picture role', () {
    expect(
      imageFrameKind(_frame(fitMode: 'roi', roleId: 'zoom')),
      'zoom',
    );
    expect(
      imageFrameKind(_frame(fitMode: 'contain', roleId: 'overall')),
      'overall',
    );
    expect(
      imageFrameKind(_frame(fitMode: 'contain', roleId: 'comparison')),
      'comparison',
    );
    expect(
      imageFrameKind(_frame(fitMode: 'contain', roleId: 'image')),
      'image',
    );
  });

  testWidgets('places frames, images, and text on the layout rectangles', (
    tester,
  ) async {
    final imagePath = _writePng();
    addTearDown(() => File(imagePath).deleteSync());
    final result = parseLayoutResult(
      _layoutJson(imagePath, missingPath: r'C:\missing\comparison.png'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SlidePreview(result: result)),
      ),
    );

    final canvas = tester.widget<SizedBox>(
      find.byKey(const Key('slide-canvas')),
    );
    expect(canvas.width, 960);
    expect(canvas.height, 540);
    expect(
      tester.widget<FittedBox>(find.byType(FittedBox)).fit,
      BoxFit.contain,
    );

    _expectRect(tester, 'frame:frame-overall', 36, 36, 438, 360);
    _expectRect(tester, 'image:frame-overall', 36, 106.5, 438, 219);
    _expectRect(tester, 'frame:frame-compare', 486, 36, 438, 360);
    _expectRect(tester, 'image:frame-compare', 615, 36, 180, 360);
    _expectRect(tester, 'text:text-caption', 36, 408, 888, 96);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.fill);
    expect(find.byKey(const Key('missing:frame-compare')), findsOneWidget);
    expect(find.byKey(const Key('unassigned:frame-compare')), findsNothing);

    final text = tester.widget<Text>(
      find.byKey(const Key('text-body:text-caption')),
    );
    expect(text.data, _caption);
    expect(text.overflow, TextOverflow.clip);
    expect(text.maxLines, isNull);
  });

  testWidgets('the selected asset marks the image frames that use it', (
    tester,
  ) async {
    final imagePath = _writePng();
    addTearDown(() => File(imagePath).deleteSync());
    final result = parseLayoutResult(
      _layoutJson(imagePath, missingPath: r'C:\missing\comparison.png'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidePreview(
            result: result,
            highlightedFrameIds: const {'frame-overall', 'text-caption'},
            highlightedAssetName: '全体画像',
            displacedAssetName: '  比較画像の全文  ',
            shareTargetFrameId: 'frame-compare',
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('shared-use:frame-overall')), findsOneWidget);
    expect(find.text('使用中\n全体画像'), findsOneWidget);
    expect(find.byKey(const Key('shared-use:frame-compare')), findsNothing);
    expect(find.byKey(const Key('shared-use:text-caption')), findsNothing);
    final label = tester.widget<Text>(
      find.byKey(const Key('shared-use-label:frame-overall')),
    );
    expect(label.data, '使用中\n全体画像');
    expect(label.overflow, TextOverflow.clip);
    expect(label.softWrap, isTrue);
    expect(label.maxLines, isNull);
    expect(find.byKey(const Key('share-target:frame-compare')), findsOneWidget);
    expect(
      find.text('共有先\n全体画像\n未割当になる:   比較画像の全文  '),
      findsOneWidget,
    );
    expect(find.byKey(const Key('share-target:frame-overall')), findsNothing);
    final target = tester.widget<Text>(
      find.byKey(const Key('share-target-label:frame-compare')),
    );
    expect(
      target.data,
      '共有先\n全体画像\n未割当になる:   比較画像の全文  ',
    );
    expect(target.overflow, TextOverflow.clip);
    expect(target.softWrap, isTrue);
    expect(target.maxLines, isNull);
    expect(shareTargetFrame(result, 'text-caption'), isNull);
  });

  test('the in-use label keeps the full asset name', () {
    expect(sharedUseLabel('全体画像'), '使用中\n全体画像');
    expect(
      sharedUseLabel('  とても長い素材名でも短縮しない  '),
      '使用中\nとても長い素材名でも短縮しない',
    );
    expect(sharedUseLabel('   '), '使用中');
    expect(sharedUseLabel(null), '使用中');
  });

  test('the share target label keeps the full asset name', () {
    expect(shareTargetLabel('全体画像'), '共有先\n全体画像');
    expect(
      shareTargetLabel('  とても長い素材名でも短縮しない  '),
      '共有先\nとても長い素材名でも短縮しない',
    );
    expect(shareTargetLabel('   '), '共有先');
    expect(shareTargetLabel(null), '共有先');
    expect(
      shareTargetLabel(
        '全体画像',
        displacedName: '  比較画像の全文  ',
      ),
      '共有先\n全体画像\n未割当になる:   比較画像の全文  ',
    );
    expect(shareTargetLabel('全体画像', displacedName: '   '), '共有先\n全体画像');
  });

  test('a drop hits the topmost image frame in slide points', () {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": null,
            "text": null,
            "assetPath": "C:\\\\images\\\\overall.png",
            "fitMode": "contain"
          },
          {
            "elementId": "frame-compare",
            "kind": "image_frame",
            "roleId": "comparison",
            "displayName": "比較画像",
            "frame": {"x": 400, "y": 36, "width": 120, "height": 80},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "frame-zoom",
            "kind": "image_frame",
            "roleId": "zoom",
            "displayName": "拡大",
            "frame": {"x": 700, "y": 36, "width": 200, "height": 200},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          }
        ],
        "violations": []
      }
    ''');

    final assigned = imageFrameAt(result, 50, 50);
    final unassigned = imageFrameAt(result, 410, 40);
    final zoom = imageFrameAt(result, 710, 40);
    expect(assigned?.elementId, 'frame-overall');
    expect(isUnassignedFrame(assigned!), isFalse);
    expect(acceptsImageDrop(assigned), isTrue);
    expect(unassigned?.elementId, 'frame-compare');
    expect(isUnassignedFrame(unassigned!), isTrue);
    expect(acceptsImageDrop(unassigned), isTrue);
    expect(zoom?.elementId, 'frame-zoom');
    expect(isUnassignedFrame(zoom!), isFalse);
    expect(acceptsImageDrop(zoom), isFalse);
    expect(imageDropLabel(assigned), '置き換え');
    expect(imageDropLabel(unassigned), '割り当て');
    expect(imageDropLabel(zoom), isNull);
    expect(imageDropTargetId(result, 50, 50), 'frame-overall');
    expect(imageDropTargetId(result, 410, 40), 'frame-compare');
    expect(imageDropTargetId(result, 710, 40), isNull);
    expect(imageFrameAt(result, 0, 0), isNull);
    expect(imageDropTargetId(result, 0, 0), isNull);
  });

  testWidgets('an unassigned contain frame is labeled on the slide', (
    tester,
  ) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-compare",
            "kind": "image_frame",
            "roleId": "comparison",
            "displayName": "比較画像",
            "frame": {"x": 486, "y": 36, "width": 438, "height": 360},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "frame-zoom",
            "kind": "image_frame",
            "roleId": "zoom",
            "displayName": "拡大",
            "frame": {"x": 486, "y": 36, "width": 240, "height": 360},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          }
        ],
        "violations": []
      }
    ''');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SlidePreview(result: result)),
      ),
    );

    final label = tester.widget<Text>(
      find.byKey(const Key('unassigned:frame-compare')),
    );
    expect(label.data, '比較画像\n未割当');
    expect(label.maxLines, isNull);
    expect(label.overflow, TextOverflow.clip);
    _expectRect(tester, 'frame:frame-compare', 486, 36, 438, 360);
    expect(find.byKey(const Key('unassigned:frame-zoom')), findsNothing);
    expect(find.byKey(const Key('image:frame-compare')), findsNothing);
  });

  test('crop placement shifts the source image so only the roi is visible', () {
    const crop = SlideRect(x: 0.1, y: 0.2, width: 0.2, height: 0.6);
    final placement = cropPlacement(boxWidth: 240, boxHeight: 360, crop: crop);
    expect(placement.width, 1200);
    expect(placement.height, 600);
    expect(placement.dx, -120);
    expect(placement.dy, -120);
  });

  testWidgets('draws the roi on the source image rectangle', (tester) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "roi-1",
            "kind": "roi",
            "roleId": "roi",
            "displayName": "ROI",
            "frame": {"x": 79.8, "y": 150.3, "width": 87.6, "height": 131.4},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          }
        ],
        "violations": []
      }
    ''');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SlidePreview(result: result)),
      ),
    );
    final positioned = tester.widget<Positioned>(
      find.byKey(const Key('roi:roi-1')),
    );
    expect(positioned.left, closeTo(79.8, 0.001));
    expect(positioned.top, closeTo(150.3, 0.001));
    expect(positioned.width, closeTo(87.6, 0.001));
    expect(positioned.height, closeTo(131.4, 0.001));
    expect(find.byKey(const Key('roi-move:roi-1')), findsNothing);
  });

  testWidgets(
    'drag reports a new roi frame and does not move the source image',
    (tester) async {
      final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 36, "y": 106.5, "width": 438, "height": 219},
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "roi-1",
            "kind": "roi",
            "roleId": "roi",
            "displayName": "ROI",
            "frame": {"x": 79.8, "y": 150.3, "width": 87.6, "height": 131.4},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi",
            "sourceElementId": "frame-overall"
          }
        ],
        "violations": []
      }
    ''');
      SlideRect? reported;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlidePreview(
              result: result,
              onRoiFrameChanged: (_, frame) => reported = frame,
              onRoiFrameCommitted: (_, _) {},
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('roi-resize:roi-1')), findsOneWidget);
      expect(find.byKey(const Key('roi-resize-nw:roi-1')), findsOneWidget);
      expect(find.byKey(const Key('roi-resize-ne:roi-1')), findsOneWidget);
      expect(find.byKey(const Key('roi-resize-sw:roi-1')), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('roi-move:roi-1')),
        const Offset(40, 0),
      );

      expect(reported, isNotNull);
      expect(reported!.x, greaterThan(79.8));
      expect(reported!.width, closeTo(87.6, 0.001));
      expect(
        reported!.x + reported!.width,
        lessThanOrEqualTo(36 + 438 + 0.001),
      );
      final image = tester.widget<Positioned>(
        find.byKey(const Key('image:frame-overall')),
      );
      expect(image.left, 36);
      expect(image.top, 106.5);
    },
  );

  testWidgets('dragging the top-left handle keeps the opposite corner', (
    tester,
  ) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 36, "y": 106.5, "width": 438, "height": 219},
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "roi-1",
            "kind": "roi",
            "roleId": "roi",
            "displayName": "ROI",
            "frame": {"x": 79.8, "y": 150.3, "width": 87.6, "height": 131.4},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi",
            "sourceElementId": "frame-overall"
          }
        ],
        "violations": []
      }
    ''');
    SlideRect? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidePreview(
            result: result,
            onRoiFrameChanged: (_, frame) => reported = frame,
            onRoiFrameCommitted: (_, _) {},
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const Key('roi-resize-nw:roi-1')),
      const Offset(-30, -20),
    );

    expect(reported, isNotNull);
    expect(reported!.x, lessThan(79.8));
    expect(reported!.y, lessThan(150.3));
    expect(reported!.x + reported!.width, closeTo(79.8 + 87.6, 0.001));
    expect(reported!.y + reported!.height, closeTo(150.3 + 131.4, 0.001));
    expect(reported!.x, greaterThanOrEqualTo(36));
    expect(reported!.y, greaterThanOrEqualTo(106.5));
  });

  testWidgets('dragging a contain image proposes a new roi', (tester) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 36, "y": 106.5, "width": 438, "height": 219},
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "frame-zoom",
            "kind": "image_frame",
            "roleId": "zoom",
            "displayName": "拡大画像",
            "frame": {"x": 486, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 585, "y": 36, "width": 240, "height": 360},
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          }
        ],
        "violations": []
      }
    ''');
    String? sourceId;
    SlideRect? created;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidePreview(
            result: result,
            onRoiCreated: (id, frame) {
              sourceId = id;
              created = frame;
            },
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('roi-create:frame-overall')), findsOneWidget);
    expect(find.byKey(const Key('roi-create:frame-zoom')), findsNothing);

    final target = find.byKey(const Key('roi-create:frame-overall'));
    final gesture = await tester.startGesture(tester.getCenter(target));
    await gesture.moveBy(const Offset(70, 40));
    await tester.pump();
    expect(find.byKey(const Key('roi-draft')), findsOneWidget);
    await gesture.up();
    await tester.pump();

    expect(sourceId, 'frame-overall');
    expect(created, isNotNull);
    expect(created!.width, greaterThanOrEqualTo(8));
    expect(created!.height, greaterThanOrEqualTo(8));
    expect(created!.x, greaterThanOrEqualTo(36));
    expect(created!.x + created!.width, lessThanOrEqualTo(36 + 438 + 0.001));
    expect(find.byKey(const Key('roi-draft')), findsNothing);
    final image = tester.widget<Positioned>(
      find.byKey(const Key('image:frame-overall')),
    );
    expect(image.left, 36);
    expect(image.top, 106.5);
  });

  testWidgets('tapping a contain frame selects it as the share target', (
    tester,
  ) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 36, "y": 106.5, "width": 438, "height": 219},
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "frame-zoom",
            "kind": "image_frame",
            "roleId": "zoom",
            "displayName": "拡大画像",
            "frame": {"x": 486, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 585, "y": 36, "width": 240, "height": 360},
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          }
        ],
        "violations": []
      }
    ''');
    String? selectedId;
    String? createdId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidePreview(
            result: result,
            onContainFrameSelected: (id) => selectedId = id,
            onRoiCreated: (id, frame) => createdId = id,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('roi-create:frame-overall')));
    await tester.pump();
    expect(selectedId, 'frame-overall');
    expect(createdId, isNull);

    final frame = tester.getRect(find.byKey(const Key('frame:frame-overall')));
    await tester.tapAt(frame.topCenter + const Offset(0, 4));
    await tester.pump();
    expect(selectedId, 'frame-overall');

    selectedId = null;
    final zoom = tester.getRect(find.byKey(const Key('frame:frame-zoom')));
    await tester.tapAt(zoom.topLeft + const Offset(4, 4));
    await tester.pump();
    expect(selectedId, 'frame-zoom');
    expect(find.byKey(const Key('frame-select:frame-zoom')), findsOneWidget);
    expect(find.byKey(const Key('frame-select:frame-overall')), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidePreview(
            result: result,
            selectedFrameId: 'frame-zoom',
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('selected-frame:frame-zoom')), findsOneWidget);
    expect(find.text('拡大画像'), findsOneWidget);
  });

  testWidgets('tap selects an roi and leaves its frame in place', (
    tester,
  ) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 36, "y": 106.5, "width": 438, "height": 219},
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          },
          {
            "elementId": "roi-1",
            "kind": "roi",
            "roleId": "roi",
            "displayName": "ROI",
            "frame": {"x": 79.8, "y": 150.3, "width": 87.6, "height": 131.4},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi",
            "sourceElementId": "frame-overall"
          }
        ],
        "violations": []
      }
    ''');
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return SlidePreview(
                result: result,
                selectedRoiId: selected,
                onRoiSelected: (roiId) => setState(() => selected = roiId),
                onRoiFrameChanged: (_, _) {},
                onRoiFrameCommitted: (_, _) {},
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('roi-move:roi-1')));
    await tester.pump();

    expect(selected, 'roi-1');
    expect(find.byKey(const Key('roi-selected:roi-1')), findsOneWidget);
    final positioned = tester.widget<Positioned>(
      find.byKey(const Key('roi:roi-1')),
    );
    expect(positioned.left, closeTo(79.8, 0.001));
    expect(positioned.top, closeTo(150.3, 0.001));
  });

  testWidgets('draws the note and connector without moving the roi', (
    tester,
  ) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "roi-1",
            "kind": "roi",
            "roleId": "roi",
            "displayName": "ROI",
            "frame": {"x": 79.8, "y": 150.3, "width": 87.6, "height": 131.4},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          },
          {
            "elementId": "roi-1-connector",
            "kind": "connector",
            "roleId": "connector",
            "displayName": "ROI の接続線",
            "frame": {"x": 167.4, "y": 216, "width": 12, "height": 0},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "contain",
            "lineStart": {"x": 167.4, "y": 216},
            "lineEnd": {"x": 179.4, "y": 216}
          },
          {
            "elementId": "roi-1-note",
            "kind": "roi_label",
            "roleId": "roi_note",
            "displayName": "ROI の注釈",
            "frame": {"x": 179.4, "y": 184, "width": 180, "height": 64},
            "contentRect": null,
            "text": "傷の注釈",
            "assetPath": null,
            "fitMode": "contain"
          }
        ],
        "violations": []
      }
    ''');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SlidePreview(result: result)),
      ),
    );
    expect(find.text('傷の注釈'), findsOneWidget);
    expect(find.byKey(const Key('connector:roi-1-connector')), findsOneWidget);
    final roi = tester.widget<Positioned>(find.byKey(const Key('roi:roi-1')));
    expect(roi.left, closeTo(79.8, 0.001));
    final note = tester.widget<Positioned>(
      find.byKey(const Key('note:roi-1-note')),
    );
    expect(note.left, closeTo(179.4, 0.001));
    expect(note.width, closeTo(180, 0.001));
    expect(find.byKey(const Key('note-move:roi-1')), findsNothing);
  });

  testWidgets('dragging a note reports the new frame and keeps the roi', (
    tester,
  ) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "roi-1",
            "kind": "roi",
            "roleId": "roi",
            "displayName": "ROI",
            "frame": {"x": 79.8, "y": 150.3, "width": 87.6, "height": 131.4},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          },
          {
            "elementId": "roi-1-note",
            "kind": "roi_label",
            "roleId": "roi_note",
            "displayName": "ROI の注釈",
            "frame": {"x": 179.4, "y": 184, "width": 180, "height": 64},
            "contentRect": null,
            "text": "傷の注釈",
            "assetPath": null,
            "fitMode": "contain",
            "sourceElementId": "roi-1"
          }
        ],
        "violations": []
      }
    ''');
    SlideRect? reported;
    var current = result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return SlidePreview(
                result: current,
                onNoteFrameChanged: (roiId, frame) {
                  reported = frame;
                  setState(() => current = moveNoteLabel(result, roiId, frame));
                },
                onNoteFrameCommitted: (_, _) {},
              );
            },
          ),
        ),
      ),
    );

    await tester.drag(find.byKey(const Key('note-move:roi-1')), const Offset(40, 0));
    await tester.pump();

    expect(reported, isNotNull);
    expect(reported!.x, greaterThan(179.4));
    expect(reported!.width, closeTo(180, 0.001));
    expect(reported!.height, closeTo(64, 0.001));
    final roi = tester.widget<Positioned>(find.byKey(const Key('roi:roi-1')));
    expect(roi.left, closeTo(79.8, 0.001));
  });

  testWidgets('zoom and pan move the view and keep slide points', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "contain"
          }
        ],
        "violations": []
      }
    ''');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SlidePreview(result: result)),
      ),
    );
    final fitted = tester.widget<Positioned>(
      find.byKey(const Key('preview-slide')),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('preview-zoom-out')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('preview-zoom-in')));
    await tester.pump();
    final zoomed = tester.widget<Positioned>(
      find.byKey(const Key('preview-slide')),
    );
    expect(zoomed.width!, greaterThan(fitted.width!));
    expect(find.text('表示 125%'), findsOneWidget);
    expect(
      tester.widget<SizedBox>(find.byKey(const Key('slide-canvas'))).width,
      960,
    );
    expect(
      tester
          .widget<Positioned>(find.byKey(const Key('frame:frame-overall')))
          .left,
      36,
    );

    await tester.tap(find.byKey(const Key('preview-pan-mode')));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('preview-pan')),
      const Offset(30, 0),
    );
    await tester.pump();
    final panned = tester.widget<Positioned>(
      find.byKey(const Key('preview-slide')),
    );
    expect(panned.left!, greaterThan(zoomed.left!));
    expect(
      tester
          .widget<Positioned>(find.byKey(const Key('frame:frame-overall')))
          .left,
      36,
    );

    await tester.tap(find.byKey(const Key('preview-view-fit')));
    await tester.pump();
    final restored = tester.widget<Positioned>(
      find.byKey(const Key('preview-slide')),
    );
    expect(restored.width, closeTo(fitted.width!, 0.001));
    expect(restored.left, closeTo(fitted.left!, 0.001));
    expect(find.text('表示 100%'), findsOneWidget);
  });

  testWidgets('a table cell keeps its full text and can be selected', (
    tester,
  ) async {
    String? tapped;
    final result = LayoutResult(
      schemaVersion: 1,
      slideWidthPt: 960,
      slideHeightPt: 540,
      elements: [
        PlacedElement(
          elementId: 'table-measure',
          kind: 'table',
          roleId: 'table',
          displayName: '測定',
          frame: const SlideRect(x: 36, y: 400, width: 200, height: 72),
          contentRect: null,
          text: null,
          assetPath: null,
          fitMode: 'contain',
          crop: null,
          tableRows: const [
            ['項目', '  値  '],
            ['結果', ''],
          ],
        ),
      ],
      violations: const [],
      skippedElementIds: const [],
      previewMode: 'provisional',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlidePreview(
            result: result,
            onTableCellSelected: (elementId, row, column) {
              tapped = '$elementId:$row:$column';
            },
          ),
        ),
      ),
    );

    expect(find.text('  値  '), findsOneWidget);
    await tester.tap(find.byKey(const Key('table-cell:table-measure:0:1')));
    expect(tapped, 'table-measure:0:1');
  });

  testWidgets('draws the page title over the template chrome', (tester) async {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 540,
        "slideHeightPt": 720,
        "previewMode": "provisional",
        "titleText": "撮像画像",
        "titleFontPt": 18,
        "titleColor": "#1A1A1A",
        "chromeImage": "C:\\\\missing\\\\chrome.png",
        "titleFrame": {"x": 20, "y": 8, "width": 200, "height": 32},
        "elements": [],
        "violations": []
      }
    ''');

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SlidePreview(result: result))),
    );

    expect(find.byKey(const Key('slide-title')), findsOneWidget);
    expect(find.text('撮像画像'), findsOneWidget);
    expect(find.byKey(const Key('slide-chrome')), findsOneWidget);
    final canvas = tester.widget<SizedBox>(find.byKey(const Key('slide-canvas')));
    expect(canvas.width, 540);
    expect(canvas.height, 720);
  });
}

PlacedElement _frame({required String fitMode, required String roleId}) {
  return PlacedElement(
    elementId: 'frame',
    kind: 'image_frame',
    roleId: roleId,
    displayName: '画像',
    frame: const SlideRect(x: 0, y: 0, width: 10, height: 10),
    contentRect: null,
    text: null,
    assetPath: null,
    fitMode: fitMode,
    crop: null,
  );
}

void _expectRect(
  WidgetTester tester,
  String key,
  double x,
  double y,
  double width,
  double height,
) {
  final positioned = tester.widget<Positioned>(find.byKey(Key(key)));
  expect(positioned.left, x);
  expect(positioned.top, y);
  expect(positioned.width, width);
  expect(positioned.height, height);
}

String _writePng() {
  final file = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}srb_preview.png',
  );
  file.writeAsBytesSync(_png);
  return file.path;
}

String _layoutJson(String imagePath, {required String missingPath}) {
  final encodedImage = imagePath.replaceAll(r'\', r'\\');
  final encodedMissing = missingPath.replaceAll(r'\', r'\\');
  return '''
{
  "schemaVersion": 1,
  "slideWidthPt": 960.0,
  "slideHeightPt": 540.0,
  "elements": [
    {
      "elementId": "frame-overall",
      "kind": "image_frame",
      "roleId": "overall",
      "displayName": "全体画像",
      "frame": {"x": 36.0, "y": 36.0, "width": 438.0, "height": 360.0},
      "contentRect": {"x": 36.0, "y": 106.5, "width": 438.0, "height": 219.0},
      "text": null,
      "assetPath": "$encodedImage",
      "fitMode": "contain"
    },
    {
      "elementId": "frame-compare",
      "kind": "image_frame",
      "roleId": "comparison",
      "displayName": "比較画像",
      "frame": {"x": 486.0, "y": 36.0, "width": 438.0, "height": 360.0},
      "contentRect": {"x": 615.0, "y": 36.0, "width": 180.0, "height": 360.0},
      "text": null,
      "assetPath": "$encodedMissing",
      "fitMode": "contain"
    },
    {
      "elementId": "text-caption",
      "kind": "text",
      "roleId": "caption",
      "displayName": "説明",
      "frame": {"x": 36.0, "y": 408.0, "width": 888.0, "height": 96.0},
      "contentRect": null,
      "text": "$_caption",
      "assetPath": null,
      "fitMode": "contain"
    }
  ],
  "violations": []
}
''';
}

const _caption =
    'これは編集可能な説明文です。レイアウトの都合で短縮、削除してはいけません。画像は縦横比を維持し、枠内に Contain で配置します。';

const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x00,
  0x03,
  0x00,
  0x01,
  0x00,
  0x05,
  0xFE,
  0x02,
  0xFE,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
