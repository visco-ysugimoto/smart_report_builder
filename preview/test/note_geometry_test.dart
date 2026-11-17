import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/note_geometry.dart';

void main() {
  test('connector meets the facing edge midpoints', () {
    const roi = SlideRect(x: 79.8, y: 150.3, width: 87.6, height: 131.4);
    const label = SlideRect(x: 179.4, y: 184, width: 180, height: 64);

    final ends = connectorEnds(roi, label);

    expect(ends.start.x, closeTo(167.4, 0.001));
    expect(ends.start.y, closeTo(216, 0.001));
    expect(ends.end.x, closeTo(179.4, 0.001));
    expect(ends.end.y, closeTo(216, 0.001));
  });

  test('the arrow points at the roi end of the connector', () {
    final head = arrowHeadPoints(167.4, 216, 179.4, 216);

    expect(head, isNotNull);
    expect(head![0].x, closeTo(167.4, 0.001));
    expect(head[0].y, closeTo(216, 0.001));
    expect(head[1].x, closeTo(175.4, 0.001));
    expect(head[1].y, closeTo(220, 0.001));
    expect(head[2].x, closeTo(175.4, 0.001));
    expect(head[2].y, closeTo(212, 0.001));
    expect(arrowHeadPoints(10, 10, 10, 10), isNull);
  });

  test('moving a note keeps the roi and retargets the connector', () {
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
            "displayName": "接続線",
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
            "displayName": "注釈",
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

    final moved = moveNoteLabel(
      result,
      'roi-1',
      const SlideRect(x: 219.4, y: 184, width: 180, height: 64),
    );
    final roi = moved.elements.firstWhere((item) => item.elementId == 'roi-1');
    final note = moved.elements.firstWhere((item) => item.elementId == 'roi-1-note');
    final connector = moved.elements.firstWhere(
      (item) => item.elementId == 'roi-1-connector',
    );

    expect(roi.frame.x, closeTo(79.8, 0.001));
    expect(note.frame.x, closeTo(219.4, 0.001));
    expect(note.frame.width, closeTo(180, 0.001));
    expect(note.text, '傷の注釈');
    expect(connector.lineStart!.x, closeTo(167.4, 0.001));
    expect(connector.lineEnd!.x, closeTo(219.4, 0.001));
  });
}
