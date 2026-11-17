import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/preview_view.dart';

void main() {
  const viewport = Size(800, 600);
  const slide = Size(960, 540);

  test('fits the slide inside the viewport', () {
    expect(containScale(viewport, slide), closeTo(800 / 960, 0.0001));
    expect(containScale(Size.zero, slide), 1);
    final fitted = previewSlideRect(fittedPreview, viewport, slide);
    expect(fitted.width, closeTo(800, 0.001));
    expect(fitted.height, closeTo(450, 0.001));
    expect(fitted.left, closeTo(0, 0.001));
    expect(fitted.top, closeTo(75, 0.001));
  });

  test('zoom keeps the slide point under the pointer', () {
    const focal = Offset(0, 75);
    final zoomed = zoomPreview(
      view: fittedPreview,
      factor: 2,
      focal: focal,
      viewport: viewport,
      slide: slide,
    );
    expect(zoomed.scale, 2);
    final rect = previewSlideRect(zoomed, viewport, slide);
    expect(rect.topLeft, focal);
    expect(rect.width, closeTo(1600, 0.001));

    final centered = zoomPreview(
      view: fittedPreview,
      factor: 2,
      focal: const Offset(400, 300),
      viewport: viewport,
      slide: slide,
    );
    expect(centered.pan, Offset.zero);
    expect(centered.scale, 2);
  });

  test('scale stays between the fitted view and the maximum', () {
    final smaller = zoomPreview(
      view: fittedPreview,
      factor: 0.5,
      focal: const Offset(400, 300),
      viewport: viewport,
      slide: slide,
    );
    expect(smaller.scale, previewViewMinScale);

    const largest = PreviewView(scale: previewViewMaxScale);
    final capped = zoomPreview(
      view: largest,
      factor: 2,
      focal: const Offset(400, 300),
      viewport: viewport,
      slide: slide,
    );
    expect(capped.scale, previewViewMaxScale);
  });

  test('pan keeps part of the slide inside the viewport', () {
    const zoomed = PreviewView(scale: 2);
    final moved = panPreview(
      view: zoomed,
      delta: const Offset(10000, -10000),
      viewport: viewport,
      slide: slide,
    );
    final rect = previewSlideRect(moved, viewport, slide);
    expect(rect.right, greaterThanOrEqualTo(previewViewMargin));
    expect(rect.bottom, greaterThanOrEqualTo(previewViewMargin));
    expect(rect.left, lessThanOrEqualTo(viewport.width - previewViewMargin));
    expect(rect.top, lessThanOrEqualTo(viewport.height - previewViewMargin));
  });
}
