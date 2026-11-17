import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_path.dart';
import 'package:smart_report_preview/layout_result.dart';

void main() {
  test('reads the imaging title and chrome without requiring them', () {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 540,
        "slideHeightPt": 720,
        "previewMode": "provisional",
        "titleText": "キズ検査",
        "titleColor": "#112233",
        "titleFrame": {"x": 10, "y": 12, "width": 180, "height": 28},
        "elements": [],
        "violations": []
      }
    ''');

    expect(result.titleText, 'キズ検査');
    expect(result.titleFrame!.x, 10);
    expect(result.chromeImage, isNull);
    expect(result.replaceFrame('missing', result.titleFrame!).titleText, 'キズ検査');
  });

  test('parses the sample slide coordinates without changing them', () {
    final result = parseLayoutResult(_sampleJson);

    expect(result.slideWidthPt, 960);
    expect(result.slideHeightPt, 540);
    expect(result.elements, hasLength(2));

    final overall = result.elements[0];
    expect(overall.frame.x, 36);
    expect(overall.frame.y, 36);
    expect(overall.frame.width, 438);
    expect(overall.frame.height, 360);
    expect(overall.contentRect!.x, 36);
    expect(overall.contentRect!.y, 106.5);
    expect(overall.contentRect!.width, 438);
    expect(overall.contentRect!.height, 219);

    final caption = result.elements[1];
    expect(caption.frame.y, 408);
    expect(caption.frame.width, 888);
    expect(caption.frame.height, 96);
    expect(caption.text, _caption);
    expect(result.violations.single.code, 'overflow');
  });

  test('keeps an roi rectangle instead of skipping it', () {
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
            "fitMode": "roi",
            "crop": {"x": 0.1, "y": 0.2, "width": 0.2, "height": 0.6},
            "sourceElementId": "frame-overall"
          }
        ],
        "violations": []
      }
    ''');
    final roi = result.elements.single;
    expect(roi.kind, 'roi');
    expect(roi.frame.x, closeTo(79.8, 0.001));
    expect(roi.crop!.width, closeTo(0.2, 0.001));
    expect(roi.sourceElementId, 'frame-overall');
    expect(result.skippedElementIds, isEmpty);
  });

  test('a report pptx opens its layout and a template uses a preview folder', () {
    final root = Directory.systemTemp.createTempSync('pptx-preview');
    addTearDown(() => root.deleteSync(recursive: true));
    final separator = Platform.pathSeparator;
    final layout = File('${root.path}${separator}layout.json')..writeAsStringSync('{}');
    final report = File('${root.path}${separator}report.pptx')..writeAsStringSync('x');
    expect(existingLayoutForPptx(report.path), layout.path);

    final template = File('${root.path}${separator}deck.pptx')..writeAsStringSync('x');
    expect(existingLayoutForPptx(template.path), isNull);
    expect(
      previewDirectoryForPptx(template.path),
      '${root.path}${separator}deck.preview',
    );

    final previewLayout = File(
      '${root.path}${separator}deck.preview${separator}layout.json',
    );
    previewLayout.parent.createSync();
    previewLayout.writeAsStringSync('{}');
    expect(existingLayoutForPptx(template.path), previewLayout.path);
  });

  test('resolves the sample layout next to the preview directory', () {
    final resolved = layoutPathFrom(
      r'C:\python_project\report-automation\smart_report_builder\preview',
      ['..', 'output', 'sample_a.layout.json'],
    );
    expect(
      resolved,
      r'C:\python_project\report-automation\smart_report_builder\output\sample_a.layout.json',
    );
    expect(File(resolved).existsSync(), isTrue);
  });

  test('rejects an unsupported schema and records an unknown element', () {
    expect(
      () => parseLayoutResult('{"schemaVersion": 999}'),
      throwsFormatException,
    );
    expect(() => parseLayoutResult('[]'), throwsFormatException);

    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
          {"elementId": "table-1", "kind": "chart"}
        ],
        "violations": []
      }
    ''');
    expect(result.elements, isEmpty);
    expect(result.skippedElementIds, ['table-1']);
    expect(result.previewMode, 'provisional');
  });

  test('a slide with contain images reports real or partial data', () {
    expect(previewModeLabel('real'), '実データプレビュー');
    expect(previewModeLabel('partial'), '一部が実データ');
    expect(previewModeLabel('provisional'), '仮プレビュー');
    expect(previewModeLabel('other'), '仮プレビュー');
    final real = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "previewMode": "real",
        "elements": [
          {
            "elementId": "frame-overall",
            "kind": "image_frame",
            "roleId": "overall",
            "displayName": "全体画像",
            "frame": {"x": 36, "y": 36, "width": 438, "height": 360},
            "contentRect": {"x": 36, "y": 106.5, "width": 438, "height": 219},
            "text": null,
            "assetPath": "overall.png",
            "fitMode": "contain"
          }
        ],
        "violations": []
      }
    ''');
    expect(real.previewMode, 'real');
    final derived = parseLayoutResult('''
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
          },
          {
            "elementId": "frame-zoom",
            "kind": "image_frame",
            "roleId": "zoom",
            "displayName": "拡大画像",
            "frame": {"x": 486, "y": 36, "width": 438, "height": 360},
            "contentRect": null,
            "text": null,
            "assetPath": null,
            "fitMode": "roi"
          }
        ],
        "violations": []
      }
    ''');
    expect(derived.previewMode, 'provisional');
    expect(previewModeOf(derived.elements), 'provisional');
  });

  test('reads a roi label and its connector', () {
    final result = parseLayoutResult('''
      {
        "schemaVersion": 1,
        "slideWidthPt": 960,
        "slideHeightPt": 540,
        "elements": [
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
    expect(result.skippedElementIds, isEmpty);
    expect(result.elements[0].lineStart!.x, closeTo(167.4, 0.001));
    expect(result.elements[0].lineEnd!.x, closeTo(179.4, 0.001));
    expect(result.elements[1].text, '傷の注釈');
  });
}

const _caption =
    'これは編集可能な説明文です。レイアウトの都合で短縮、削除してはいけません。画像は縦横比を維持し、枠内に Contain で配置します。';

const _sampleJson =
    '''
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
      "assetPath": null,
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
  "violations": [
    {"code": "overflow", "elementId": "text-caption", "message": "はみ出している"}
  ]
}
''';
