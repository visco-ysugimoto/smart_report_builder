import 'dart:math' as math;
import 'dart:ui';

const previewViewMinScale = 1.0;
const previewViewMaxScale = 8.0;
const previewViewScaleStep = 1.25;
const previewViewMargin = 48.0;

/// 全体表示を 1 とした、プレビュー画面の拡大率と移動量。配置計算ではない。
class PreviewView {
  const PreviewView({this.scale = previewViewMinScale, this.pan = Offset.zero});

  final double scale;
  final Offset pan;

  bool get isFitted => scale == previewViewMinScale && pan == Offset.zero;
}

/// スライド全体が枠に収まる倍率。幅か高さが無いときは 1。
double containScale(Size viewport, Size slide) {
  if (viewport.width <= 0 ||
      viewport.height <= 0 ||
      slide.width <= 0 ||
      slide.height <= 0 ||
      !viewport.width.isFinite ||
      !viewport.height.isFinite) {
    return 1;
  }
  return math.min(viewport.width / slide.width, viewport.height / slide.height);
}

/// 指の位置のスライド上の点を保ったまま拡大率を変える。
PreviewView zoomPreview({
  required PreviewView view,
  required double factor,
  required Offset focal,
  required Size viewport,
  required Size slide,
}) {
  if (factor <= 0 || !factor.isFinite) {
    return clampPreviewView(view, viewport, slide);
  }
  final nextScale = (view.scale * factor)
      .clamp(previewViewMinScale, previewViewMaxScale)
      .toDouble();
  if ((nextScale - view.scale).abs() < 1e-9) {
    return clampPreviewView(view, viewport, slide);
  }
  final fit = containScale(viewport, slide);
  final before = _slideOrigin(viewport, slide, fit, view);
  final denominator = fit * view.scale;
  final slidePoint = denominator == 0
      ? Offset.zero
      : (focal - before) / denominator;
  final drawn = fit * nextScale;
  final afterOrigin = focal - slidePoint * drawn;
  final centered = _centeredOrigin(viewport, drawn, slide);
  return clampPreviewView(
    PreviewView(scale: nextScale, pan: afterOrigin - centered),
    viewport,
    slide,
  );
}

PreviewView panPreview({
  required PreviewView view,
  required Offset delta,
  required Size viewport,
  required Size slide,
}) {
  return clampPreviewView(
    PreviewView(scale: view.scale, pan: view.pan + delta),
    viewport,
    slide,
  );
}

const fittedPreview = PreviewView();

/// スライドが画面から完全に出ないように移動量を収める。
PreviewView clampPreviewView(PreviewView view, Size viewport, Size slide) {
  final scale = view.scale
      .clamp(previewViewMinScale, previewViewMaxScale)
      .toDouble();
  final drawn = containScale(viewport, slide) * scale;
  final width = slide.width * drawn;
  final height = slide.height * drawn;
  final centered = _centeredOrigin(viewport, drawn, slide);
  final marginX = math
      .min(previewViewMargin, math.max(viewport.width / 2, 0))
      .toDouble();
  final marginY = math
      .min(previewViewMargin, math.max(viewport.height / 2, 0))
      .toDouble();
  final origin = _clampOrigin(
    centered + view.pan,
    width: width,
    height: height,
    viewport: viewport,
    marginX: marginX,
    marginY: marginY,
  );
  return PreviewView(scale: scale, pan: origin - centered);
}

/// 画面上でのスライドの矩形。中身の座標はスライドポイントのまま。
Rect previewSlideRect(PreviewView view, Size viewport, Size slide) {
  final drawn = containScale(viewport, slide) * view.scale;
  final origin = _centeredOrigin(viewport, drawn, slide) + view.pan;
  return Rect.fromLTWH(
    origin.dx,
    origin.dy,
    slide.width * drawn,
    slide.height * drawn,
  );
}

Offset _centeredOrigin(Size viewport, double drawn, Size slide) {
  return Offset(
    (viewport.width - slide.width * drawn) / 2,
    (viewport.height - slide.height * drawn) / 2,
  );
}

Offset _slideOrigin(Size viewport, Size slide, double fit, PreviewView view) {
  return _centeredOrigin(viewport, fit * view.scale, slide) + view.pan;
}

Offset _clampOrigin(
  Offset origin, {
  required double width,
  required double height,
  required Size viewport,
  required double marginX,
  required double marginY,
}) {
  final minX = marginX - width;
  final maxX = viewport.width - marginX;
  final minY = marginY - height;
  final maxY = viewport.height - marginY;
  return Offset(
    maxX >= minX ? origin.dx.clamp(minX, maxX).toDouble() : origin.dx,
    maxY >= minY ? origin.dy.clamp(minY, maxY).toDouble() : origin.dy,
  );
}
