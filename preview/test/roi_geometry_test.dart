import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/roi_geometry.dart';

void main() {
  const image = SlideRect(x: 36, y: 106.5, width: 438, height: 219);
  const roi = SlideRect(x: 79.8, y: 150.3, width: 87.6, height: 131.4);

  test('moves inside the source image and clamps at the edge', () {
    final moved = moveRoi(roi, image, 10, -5);
    expect(moved.x, closeTo(89.8, 0.001));
    expect(moved.y, closeTo(145.3, 0.001));
    expect(moved.width, closeTo(87.6, 0.001));

    final clamped = moveRoi(roi, image, -1000, 1000);
    expect(clamped.x, image.x);
    expect(clamped.y, closeTo(image.y + image.height - roi.height, 0.001));
    expect(clamped.width, roi.width);
  });

  test('resize stays inside the source image', () {
    final grown = resizeRoi(roi, image, 20, 10);
    expect(grown.x, roi.x);
    expect(grown.y, roi.y);
    expect(grown.width, closeTo(107.6, 0.001));
    expect(grown.height, closeTo(141.4, 0.001));

    final limited = resizeRoi(roi, image, 10000, 10000);
    expect(limited.x, roi.x);
    expect(limited.width, closeTo(image.x + image.width - roi.x, 0.001));
    expect(limited.height, closeTo(image.y + image.height - roi.y, 0.001));
  });

  test('each corner moves alone and keeps the opposite corner fixed', () {
    const right = 79.8 + 87.6;
    const bottom = 150.3 + 131.4;

    final topLeft = resizeRoiFromCorner(roi, image, RoiCorner.topLeft, -10, -8);
    expect(topLeft.x, closeTo(69.8, 0.001));
    expect(topLeft.y, closeTo(142.3, 0.001));
    expect(topLeft.x + topLeft.width, closeTo(right, 0.001));
    expect(topLeft.y + topLeft.height, closeTo(bottom, 0.001));

    final topRight = resizeRoiFromCorner(
      roi,
      image,
      RoiCorner.topRight,
      20,
      -10,
    );
    expect(topRight.x, roi.x);
    expect(topRight.y, closeTo(140.3, 0.001));
    expect(topRight.width, closeTo(107.6, 0.001));
    expect(topRight.y + topRight.height, closeTo(bottom, 0.001));

    final bottomLeft = resizeRoiFromCorner(
      roi,
      image,
      RoiCorner.bottomLeft,
      -20,
      10,
    );
    expect(bottomLeft.y, roi.y);
    expect(bottomLeft.x, closeTo(59.8, 0.001));
    expect(bottomLeft.height, closeTo(141.4, 0.001));
    expect(bottomLeft.x + bottomLeft.width, closeTo(right, 0.001));

    final shrunk = resizeRoiFromCorner(
      roi,
      image,
      RoiCorner.topLeft,
      10000,
      10000,
    );
    expect(shrunk.width, roiMinSizePt);
    expect(shrunk.height, roiMinSizePt);
    expect(shrunk.x + shrunk.width, closeTo(right, 0.001));
    expect(shrunk.y + shrunk.height, closeTo(bottom, 0.001));

    final clamped = resizeRoiFromCorner(
      roi,
      image,
      RoiCorner.topLeft,
      -10000,
      -10000,
    );
    expect(clamped.x, image.x);
    expect(clamped.y, image.y);
    expect(clamped.x + clamped.width, closeTo(right, 0.001));
    expect(clamped.y + clamped.height, closeTo(bottom, 0.001));
  });

  test('normalizes a slide rectangle against the displayed image', () {
    final normalized = normalizedRoi(roi, image);
    expect(normalized.x, closeTo(0.1, 0.001));
    expect(normalized.y, closeTo(0.2, 0.001));
    expect(normalized.width, closeTo(0.2, 0.001));
    expect(normalized.height, closeTo(0.6, 0.001));
  });

  test('clips a new roi to the source image', () {
    const start = Offset(50, 120);
    final inside = rectInside(start, const Offset(150, 200), image);
    expect(inside!.x, 50);
    expect(inside.y, 120);
    expect(inside.width, 100);
    expect(inside.height, 80);
    expect(canCommitRoi(inside), isTrue);

    final clipped = rectInside(start, const Offset(10, 40), image);
    expect(clipped!.x, image.x);
    expect(clipped.y, image.y);
    expect(clipped.width, closeTo(50 - image.x, 0.001));
    expect(clipped.height, closeTo(120 - image.y, 0.001));

    final tiny = rectInside(start, const Offset(52, 122), image);
    expect(tiny, isNotNull);
    expect(canCommitRoi(tiny!), isFalse);
    expect(rectInside(start, start, image), isNull);
  });

  test('resizes one side of an image frame without moving the opposite side', () {
    const frame = SlideRect(x: 40, y: 30, width: 200, height: 120);
    const bounds = SlideRect(x: 20, y: 10, width: 400, height: 300);
    final wider = resizeFrame(frame, bounds, FrameHandle.right, 50, 80);
    expect(wider.x, frame.x);
    expect(wider.y, frame.y);
    expect(wider.width, closeTo(250, 0.001));
    expect(wider.height, frame.height);

    final shorter = resizeFrame(frame, bounds, FrameHandle.bottom, 10, -40);
    expect(shorter.x, frame.x);
    expect(shorter.y, frame.y);
    expect(shorter.width, frame.width);
    expect(shorter.height, closeTo(80, 0.001));

    final shifted = resizeFrame(frame, bounds, FrameHandle.topLeft, -30, -15);
    expect(shifted.x, bounds.x);
    expect(shifted.x + shifted.width, closeTo(frame.x + frame.width, 0.001));
    expect(shifted.y, closeTo(15, 0.001));
    expect(shifted.y + shifted.height, closeTo(frame.y + frame.height, 0.001));
  });

  test('derives the project and pptx paths from the layout path', () {
    expect(
      projectPathForLayout(r'C:\reports\sample_roi.layout.json'),
      r'C:\reports\sample_roi.project.json',
    );
    expect(
      pptxPathForLayout(r'C:\reports\sample_roi.layout.json'),
      r'C:\reports\sample_roi.pptx',
    );
    expect(projectPathForLayout(r'C:\reports\sample_roi.json'), isNull);
    expect(
      projectPathForLayout(r'C:\reports\demo\layout.json'),
      r'C:\reports\demo\project.json',
    );
    expect(
      pptxPathForLayout(r'C:\reports\demo\layout.json'),
      r'C:\reports\demo\report.pptx',
    );
    expect(
      undoPathForProject(r'C:\reports\sample_roi.project.json'),
      r'C:\reports\sample_roi.project.json.undo',
    );
    expect(undoPathForProject(null), isNull);
    expect(undoPathForProject(''), isNull);
    expect(
      redoPathForProject(r'C:\reports\sample_roi.project.json'),
      r'C:\reports\sample_roi.project.json.redo',
    );
    expect(redoPathForProject(null), isNull);
  });
}
