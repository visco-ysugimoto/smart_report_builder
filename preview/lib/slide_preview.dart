import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:smart_report_preview/layout_result.dart';
import 'package:smart_report_preview/note_geometry.dart';
import 'package:smart_report_preview/preview_view.dart';
import 'package:smart_report_preview/roi_geometry.dart';

const slideFrameColor = Color(0xFF2B6CB0);

/// `#RRGGBB` をプレビューの文字色にする。読めないときは暗い灰色。
Color colorFromHex(String? hex) {
  final raw = hex?.replaceFirst('#', '') ?? '';
  if (raw.length != 6) {
    return const Color(0xFF1A1A1A);
  }
  final value = int.tryParse(raw, radix: 16);
  if (value == null) {
    return const Color(0xFF1A1A1A);
  }
  return Color(0xFF000000 | value);
}
const sharedUseColor = Color(0xFF2F855A);
const shareTargetColor = Color(0xFF6B46C1);

Widget _tableChildOf(PlacedElement element, void Function(String elementId, int row, int column)? onSelected) {
  final rows = element.tableRows ?? const <List<String>>[];
  if (rows.isEmpty) {
    return const SizedBox.expand();
  }
  return Column(
    children: [
      for (var row = 0; row < rows.length; row++)
        Expanded(
          child: Row(
            children: [
              for (var column = 0; column < rows[row].length; column++)
                Expanded(
                  child: GestureDetector(
                    key: Key('table-cell:${element.elementId}:$row:$column'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onSelected == null
                        ? null
                        : () => onSelected(element.elementId, row, column),
                    child: Text(
                      rows[row][column],
                      softWrap: true,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}

/// 通常表示の画像枠で、素材のパスがないもの。拡大枠は未割当とは表示しない。
bool isUnassignedFrame(PlacedElement element) {
  final path = element.assetPath;
  return element.kind == 'image_frame' &&
      element.fitMode == 'contain' &&
      (path == null || path.isEmpty);
}

/// ドロップで画像を受け取れるのは通常表示の画像枠。未割当でも割当済みでもよい。
bool acceptsImageDrop(PlacedElement element) {
  return element.kind == 'image_frame' && element.fitMode == 'contain';
}

/// ドラッグ中の表示文言。未割当は割り当て、既存の画像は置き換え。
String? imageDropLabel(PlacedElement element) {
  if (!acceptsImageDrop(element)) {
    return null;
  }
  return isUnassignedFrame(element) ? '割り当て' : '置き換え';
}

/// 選んだ素材を使っている画像枠。文字枠や ROI は含めない。
List<PlacedElement> framesUsingSelectedAsset(
  LayoutResult result,
  Set<String> frameIds,
) {
  if (frameIds.isEmpty) {
    return const [];
  }
  return [
    for (final element in result.elements)
      if (element.kind == 'image_frame' && frameIds.contains(element.elementId))
        element,
  ];
}

/// 使用中の表示文。素材名があるときは改行して全文を置く。
String sharedUseLabel(String? assetName) {
  final name = assetName?.trim() ?? '';
  if (name.isEmpty) {
    return '使用中';
  }
  return '使用中\n$name';
}

/// 共有先の表示文。共有しようとしている素材名と、未割当になる素材名は改行して全文を置く。
String shareTargetLabel(String? assetName, {String? displacedName}) {
  final name = assetName?.trim() ?? '';
  final displaced = displacedName ?? '';
  final lines = <String>['共有先'];
  if (name.isNotEmpty) {
    lines.add(name);
  }
  if (displaced.trim().isNotEmpty) {
    lines.add('未割当になる: $displaced');
  }
  return lines.join('\n');
}

/// 画像枠の種類。拡大は roi 表示、それ以外は役割。未知の役割は画像。
String imageFrameKind(PlacedElement frame) {
  if (frame.fitMode == 'roi') {
    return 'zoom';
  }
  if (frame.roleId == 'overall' || frame.roleId == 'comparison') {
    return frame.roleId;
  }
  return 'image';
}

/// クリックで選んだ画像枠。通常表示と拡大のどちらも返す。
PlacedElement? selectedImageFrame(LayoutResult result, String? frameId) {
  if (frameId == null) {
    return null;
  }
  for (final element in result.elements) {
    if (element.elementId == frameId && element.kind == 'image_frame') {
      return element;
    }
  }
  return null;
}

/// 共有先に選んだ通常表示の画像枠。未選択、文字枠、拡大枠は null。
PlacedElement? shareTargetFrame(LayoutResult result, String? frameId) {
  if (frameId == null) {
    return null;
  }
  for (final element in result.elements) {
    if (element.elementId == frameId &&
        element.kind == 'image_frame' &&
        element.fitMode == 'contain') {
      return element;
    }
  }
  return null;
}

/// ドラッグ中に示すドロップ先。通常表示の画像枠の上だけを返す。
String? imageDropTargetId(LayoutResult result, double x, double y) {
  final frame = imageFrameAt(result, x, y);
  if (frame == null || !acceptsImageDrop(frame)) {
    return null;
  }
  return frame.elementId;
}

/// 右クリックの対象。手前から ROI、表、画像枠の順で探す。
PlacedElement? previewHitAt(LayoutResult result, double x, double y) {
  for (final kind in const ['roi', 'table', 'image_frame']) {
    for (final element in result.elements.reversed) {
      if (element.kind != kind) {
        continue;
      }
      final frame = element.frame;
      final inside =
          x >= frame.x &&
          y >= frame.y &&
          x <= frame.x + frame.width &&
          y <= frame.y + frame.height;
      if (inside) {
        return element;
      }
    }
  }
  return null;
}

/// スライドポイントにある、いちばん手前の画像枠。枠の外なら null。
PlacedElement? imageFrameAt(LayoutResult result, double x, double y) {
  for (final element in result.elements.reversed) {
    if (element.kind != 'image_frame') {
      continue;
    }
    final frame = element.frame;
    final inside =
        x >= frame.x &&
        y >= frame.y &&
        x <= frame.x + frame.width &&
        y <= frame.y + frame.height;
    if (inside) {
      return element;
    }
  }
  return null;
}

const roiFrameColor = Color(0xFFC05621);
const previewFontSizePt = 16.0;
const roiHandlePt = 14.0;

class CropPlacement {
  const CropPlacement({
    required this.width,
    required this.height,
    required this.dx,
    required this.dy,
  });

  final double width;
  final double height;
  final double dx;
  final double dy;
}

/// 拡大枠の中で、ROI の範囲だけが見えるように元画像をずらす。
CropPlacement cropPlacement({
  required double boxWidth,
  required double boxHeight,
  required SlideRect crop,
}) {
  final width = boxWidth / crop.width;
  final height = boxHeight / crop.height;
  return CropPlacement(
    width: width,
    height: height,
    dx: -crop.x * width,
    dy: -crop.y * height,
  );
}

/// スライドポイントのまま積み、画面へはスライド全体を Contain で収める。
/// 表示の拡大と移動は画面上だけで、配置そのものは再計算しない。
/// ドラッグ中の ROI 枠だけを動かし、配置そのものは再計算しない。
class SlidePreview extends StatefulWidget {
  const SlidePreview({
    required this.result,
    this.onRoiFrameChanged,
    this.onRoiFrameCommitted,
    this.onRoiEditCancelled,
    this.onRoiCreated,
    this.onNoteFrameChanged,
    this.onNoteFrameCommitted,
    this.onImageFileDropped,
    this.onImageDropRejected,
    this.selectedRoiId,
    this.onRoiSelected,
    this.onContainFrameSelected,
    this.onImageFrameChanged,
    this.onImageFrameCommitted,
    this.selectedFrameId,
    this.onTableCellSelected,
    this.highlightedFrameIds = const {},
    this.highlightedAssetName,
    this.displacedAssetName,
    this.shareTargetFrameId,
    this.onContextMenu,
    super.key,
  });

  final LayoutResult result;
  final void Function(String roiId, SlideRect frame)? onRoiFrameChanged;
  final void Function(String roiId, SlideRect frame)? onRoiFrameCommitted;
  final VoidCallback? onRoiEditCancelled;
  final void Function(String sourceElementId, SlideRect frame)? onRoiCreated;
  final void Function(String roiId, SlideRect frame)? onNoteFrameChanged;
  final void Function(String roiId, SlideRect frame)? onNoteFrameCommitted;
  final void Function(String elementId, String imagePath)? onImageFileDropped;
  final void Function(String message)? onImageDropRejected;
  final String? selectedRoiId;
  final void Function(String roiId)? onRoiSelected;
  final void Function(String elementId)? onContainFrameSelected;
  final void Function(String elementId, SlideRect frame)? onImageFrameChanged;
  final void Function(String elementId, SlideRect frame)? onImageFrameCommitted;
  final String? selectedFrameId;
  final void Function(String elementId, int row, int column)? onTableCellSelected;
  final Set<String> highlightedFrameIds;
  final String? highlightedAssetName;
  final String? displacedAssetName;
  final String? shareTargetFrameId;
  final void Function(Offset slidePoint, Offset global)? onContextMenu;

  @override
  State<SlidePreview> createState() => _SlidePreviewState();
}

class _SlidePreviewState extends State<SlidePreview> {
  BuildContext? _canvasContext;
  Offset? _moveGrab;
  SlideRect? _moveStartFrame;
  Offset? _resizeStartLocal;
  SlideRect? _resizeStartFrame;
  RoiCorner? _resizeCorner;
  SlideRect? _lastFrame;
  String? _noteRoiId;
  Offset? _noteGrab;
  SlideRect? _noteStartFrame;
  SlideRect? _lastNoteFrame;
  Offset? _draftStart;
  String? _draftSourceId;
  SlideRect? _draftFrame;
  PreviewView _view = fittedPreview;
  bool _panMode = false;
  bool _middlePan = false;
  String? _dropTargetId;
  Size? _viewport;
  String? _liveRoiId;
  SlideRect? _liveRoiFrame;
  String? _liveNoteRoiId;
  SlideRect? _liveNoteFrame;
  String? _liveImageId;
  SlideRect? _liveImageFrame;
  String? _imageResizeId;
  FrameHandle? _imageHandle;
  Offset? _imageStartLocal;
  SlideRect? _imageStartFrame;
  SlideRect? _lastImageFrame;
  final Map<String, bool> _fileExists = {};

  bool get _editable =>
      widget.onRoiFrameChanged != null && widget.onRoiFrameCommitted != null;

  LayoutResult get _displayResult {
    var result = widget.result;
    final roiId = _liveRoiId;
    final roiFrame = _liveRoiFrame;
    if (roiId != null && roiFrame != null) {
      result = result.replaceFrame(roiId, roiFrame);
    }
    final noteId = _liveNoteRoiId;
    final noteFrame = _liveNoteFrame;
    if (noteId != null && noteFrame != null) {
      result = moveNoteLabel(result, noteId, noteFrame);
    }
    final imageId = _liveImageId;
    final imageFrame = _liveImageFrame;
    if (imageId != null && imageFrame != null) {
      result = result.replaceImageFrame(imageId, imageFrame);
    }
    return result;
  }

  @override
  void didUpdateWidget(SlidePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _liveRoiId = null;
      _liveRoiFrame = null;
      _liveNoteRoiId = null;
      _liveNoteFrame = null;
      _liveImageId = null;
      _liveImageFrame = null;
      _fileExists.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _displayResult;
    final slide = Size(result.slideWidthPt, result.slideHeightPt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              key: const Key('preview-zoom-in'),
              onPressed: _view.scale >= previewViewMaxScale
                  ? null
                  : () => _zoom(previewViewScaleStep),
              child: const Text('表示を拡大'),
            ),
            FilledButton(
              key: const Key('preview-zoom-out'),
              onPressed: _view.scale <= previewViewMinScale
                  ? null
                  : () => _zoom(1 / previewViewScaleStep),
              child: const Text('表示を縮小'),
            ),
            FilledButton(
              key: const Key('preview-view-fit'),
              onPressed: _view.isFitted ? null : _fitView,
              child: const Text('全体表示'),
            ),
            FilledButton(
              key: const Key('preview-pan-mode'),
              onPressed: () => setState(() => _panMode = !_panMode),
              child: Text(_panMode ? '移動を終了' : '表示を移動'),
            ),
            Text(
              '表示 ${(_view.scale * 100).round()}%',
              key: const Key('preview-scale'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewport = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              _viewport = viewport;
              final rect = previewSlideRect(_view, viewport, slide);
              final preview = Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    _zoom(
                      event.scrollDelta.dy < 0
                          ? previewViewScaleStep
                          : 1 / previewViewScaleStep,
                      focal: event.localPosition,
                    );
                  }
                },
                onPointerDown: (event) {
                  if ((event.buttons & kSecondaryMouseButton) != 0) {
                    final local = _canvasLocal(event.position);
                    if (local != null) {
                      widget.onContextMenu?.call(local, event.position);
                    }
                  }
                  if ((event.buttons & kMiddleMouseButton) != 0) {
                    _middlePan = true;
                  }
                },
                onPointerMove: (event) {
                  if (_middlePan) {
                    _panBy(event.delta);
                  }
                },
                onPointerUp: (event) {
                  if ((event.buttons & kMiddleMouseButton) == 0) {
                    _middlePan = false;
                  }
                },
                child: ClipRect(
                  child: ColoredBox(
                    color: const Color(0xFFE2E8F0),
                    child: Stack(
                      children: [
                        Positioned(
                          key: const Key('preview-slide'),
                          left: rect.left,
                          top: rect.top,
                          width: rect.width,
                          height: rect.height,
                          child: IgnorePointer(
                            ignoring: _panMode,
                            child: FittedBox(
                              fit: BoxFit.contain,
                              alignment: Alignment.center,
                              child: SizedBox(
                                key: const Key('slide-canvas'),
                                width: result.slideWidthPt,
                                height: result.slideHeightPt,
                                child: Builder(
                                  builder: (context) {
                                    _canvasContext = context;
                                    final highlight = _dropHighlight();
                                    final dropLabel = highlight == null
                                        ? null
                                        : imageDropLabel(highlight);
                                    return ColoredBox(
                                      color: Colors.white,
                                      child: Stack(
                                        children: [
                                          if (result.chromeImage != null &&
                                              result.chromeImage!.isNotEmpty)
                                            Positioned.fill(
                                              child: Image.file(
                                                File(result.chromeImage!),
                                                key: const Key('slide-chrome'),
                                                fit: BoxFit.fill,
                                                errorBuilder: (_, _, _) =>
                                                    const SizedBox.shrink(),
                                              ),
                                            ),
                                          if (result.titleText != null &&
                                              result.titleFrame != null)
                                            Positioned(
                                              key: const Key('slide-title'),
                                              left: result.titleFrame!.x,
                                              top: result.titleFrame!.y,
                                              width: result.titleFrame!.width,
                                              height: result.titleFrame!.height,
                                              child: IgnorePointer(
                                                child: Text(
                                                  result.titleText!,
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: result.titleFontPt ?? 18,
                                                    height: 1.1,
                                                    color: colorFromHex(result.titleColor),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          for (final element in result.elements)
                                            ..._layers(element),
                                          for (final element
                                              in framesUsingSelectedAsset(
                                                result,
                                                widget.highlightedFrameIds,
                                              ))
                                            _sharedUseMark(element),
                                          for (final element in result.elements)
                                            if (element.kind == 'image_frame' &&
                                                widget.onImageFrameCommitted != null)
                                              ..._imageFrameHandles(element),
                                          if (selectedImageFrame(
                                                result,
                                                widget.selectedFrameId,
                                              )
                                              case final chosen?)
                                            _selectedFrameMark(chosen),
                                          if (shareTargetFrame(
                                                result,
                                                widget.shareTargetFrameId,
                                              )
                                              case final target?)
                                            _shareTargetMark(target),
                                          if (highlight != null && dropLabel != null)
                                            _box(
                                              key: Key(
                                                'drop-target:${highlight.elementId}',
                                              ),
                                              rect: highlight.frame,
                                              child: IgnorePointer(
                                                child: DecoratedBox(
                                                  decoration: const BoxDecoration(
                                                    color: Color(0x332B6CB0),
                                                    border: Border.fromBorderSide(
                                                      BorderSide(
                                                        color: slideFrameColor,
                                                        width: 3,
                                                      ),
                                                    ),
                                                  ),
                                                  child: Center(
                                                    child: DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                          4,
                                                        ),
                                                      ),
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4,
                                                        ),
                                                        child: Text(
                                                          dropLabel,
                                                          key: Key(
                                                            'drop-label:${highlight.elementId}',
                                                          ),
                                                          softWrap: false,
                                                          overflow: TextOverflow.clip,
                                                          style: const TextStyle(
                                                            fontSize: 14,
                                                            color: slideFrameColor,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          if (_draftFrame != null)
                                            _box(
                                              key: const Key('roi-draft'),
                                              rect: _draftFrame!,
                                              child: const DecoratedBox(
                                                decoration: BoxDecoration(
                                                  border: Border.fromBorderSide(
                                                    BorderSide(
                                                      color: roiFrameColor,
                                                      width: 2,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_panMode)
                          Positioned.fill(
                            child: GestureDetector(
                              key: const Key('preview-pan'),
                              behavior: HitTestBehavior.opaque,
                              onPanUpdate: (details) => _panBy(details.delta),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
              if (widget.onImageFileDropped == null) {
                return preview;
              }
              return DropTarget(
                onDragEntered: _onImageDrag,
                onDragUpdated: _onImageDrag,
                onDragExited: (_) => _clearImageDrag(),
                onDragDone: _onImageDrop,
                child: preview,
              );
            },
          ),
        ),
      ],
    );
  }

  PlacedElement? _dropHighlight() {
    final id = _dropTargetId;
    if (id == null) {
      return null;
    }
    for (final element in widget.result.elements) {
      if (element.elementId == id && acceptsImageDrop(element)) {
        return element;
      }
    }
    return null;
  }

  void _onImageDrag(DropEventDetails details) {
    final local = _canvasLocal(details.globalPosition);
    final id = local == null
        ? null
        : imageDropTargetId(widget.result, local.dx, local.dy);
    if (_dropTargetId == id) {
      return;
    }
    setState(() => _dropTargetId = id);
  }

  void _clearImageDrag() {
    if (_dropTargetId == null) {
      return;
    }
    setState(() => _dropTargetId = null);
  }

  void _onImageDrop(DropDoneDetails details) {
    _clearImageDrag();
    final dropped = widget.onImageFileDropped;
    if (dropped == null) {
      return;
    }
    final local = _canvasLocal(details.globalPosition);
    final frame = local == null
        ? null
        : imageFrameAt(widget.result, local.dx, local.dy);
    if (frame == null || !acceptsImageDrop(frame)) {
      widget.onImageDropRejected?.call('通常表示の画像枠の上にドロップしてください');
      return;
    }
    if (details.files.length != 1) {
      widget.onImageDropRejected?.call('画像ファイルは一つだけドロップできます');
      return;
    }
    final path = details.files.single.path;
    if (Directory(path).existsSync()) {
      widget.onImageDropRejected?.call('フォルダの一括登録は未実装です');
      return;
    }
    dropped(frame.elementId, path);
  }

  void _zoom(double factor, {Offset? focal}) {
    final viewport = _viewport;
    final result = widget.result;
    if (viewport == null) {
      return;
    }
    final slide = Size(result.slideWidthPt, result.slideHeightPt);
    setState(() {
      _view = zoomPreview(
        view: _view,
        factor: factor,
        focal: focal ?? Offset(viewport.width / 2, viewport.height / 2),
        viewport: viewport,
        slide: slide,
      );
    });
  }

  void _panBy(Offset delta) {
    final viewport = _viewport;
    final result = widget.result;
    if (viewport == null) {
      return;
    }
    setState(() {
      _view = panPreview(
        view: _view,
        delta: delta,
        viewport: viewport,
        slide: Size(result.slideWidthPt, result.slideHeightPt),
      );
    });
  }

  void _fitView() {
    setState(() => _view = fittedPreview);
  }

  List<Widget> _layers(PlacedElement element) {
    if (element.kind == 'connector') {
      return [_connectorLine(element)];
    }
    if (element.kind == 'roi') {
      final bounds = _boundsFor(element);
      final selected = widget.selectedRoiId == element.elementId;
      if (!_editable || bounds == null) {
        return [
          _box(
            key: Key('roi:${element.elementId}'),
            rect: element.frame,
            child: widget.onRoiSelected == null
                ? const DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.fromBorderSide(
                        BorderSide(color: roiFrameColor, width: 2),
                      ),
                    ),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onRoiSelected?.call(element.elementId),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.fromBorderSide(
                          BorderSide(color: roiFrameColor, width: 2),
                        ),
                      ),
                    ),
                  ),
          ),
          if (selected) _selectedOverlay(element),
        ];
      }
      return [
        _box(
          key: Key('roi:${element.elementId}'),
          rect: element.frame,
          child: GestureDetector(
            key: Key('roi-move:${element.elementId}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onRoiSelected?.call(element.elementId),
            onPanStart: (details) =>
                _startMove(details.globalPosition, element.frame),
            onPanUpdate: (details) =>
                _updateMove(details.globalPosition, element, bounds),
            onPanEnd: (_) => _finish(element.elementId),
            onPanCancel: _cancel,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                border: Border.fromBorderSide(
                  BorderSide(color: roiFrameColor, width: 2),
                ),
              ),
            ),
          ),
        ),
        if (selected) _selectedOverlay(element),
        for (final corner in RoiCorner.values)
          _resizeHandle(element, bounds, corner),
      ];
    }
    return [
      _box(
        key: Key('frame:${element.elementId}'),
        rect: element.frame,
        child: element.kind == 'image_frame'
            ? _maybeSelectFrame(
                element,
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: isUnassignedFrame(element)
                        ? const Color(0xFFF7FAFC)
                        : null,
                    border: const Border.fromBorderSide(
                      BorderSide(color: slideFrameColor, width: 1.5),
                    ),
                  ),
                  child: isUnassignedFrame(element)
                      ? Center(
                          child: Text(
                            '${element.displayName}\n未割当',
                            key: Key('unassigned:${element.elementId}'),
                            textAlign: TextAlign.center,
                            softWrap: true,
                            overflow: TextOverflow.clip,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF2B6CB0),
                            ),
                          ),
                        )
                      : const SizedBox.expand(),
                ),
              )
            : const SizedBox.expand(),
      ),
      if (element.kind == 'image_frame' && element.contentRect != null)
        _box(
          key: Key('image:${element.elementId}'),
          rect: element.contentRect!,
          child: _imageChild(element),
        ),
      if (element.kind == 'text' || element.kind == 'roi_label')
        _box(
          key: Key(
            element.kind == 'roi_label'
                ? 'note:${element.elementId}'
                : 'text:${element.elementId}',
          ),
          rect: element.frame,
          child: _noteChild(element),
        ),
      if (element.kind == 'table')
        _box(
          key: Key('table:${element.elementId}'),
          rect: element.frame,
          child: _tableChildOf(element, widget.onTableCellSelected),
        ),
    ];
  }

  Widget _noteChild(PlacedElement element) {
    final text = Text(
      element.text ?? '',
      key: Key(
        element.kind == 'roi_label'
            ? 'note-body:${element.elementId}'
            : 'text-body:${element.elementId}',
      ),
      style: const TextStyle(
        fontFamily: 'Yu Gothic',
        fontSize: previewFontSizePt,
        height: 1,
        color: Colors.black,
      ),
      softWrap: true,
      overflow: TextOverflow.clip,
    );
    final roiId = element.sourceElementId;
    if (element.kind != 'roi_label' ||
        roiId == null ||
        widget.onNoteFrameChanged == null ||
        widget.onNoteFrameCommitted == null) {
      return IgnorePointer(ignoring: element.kind == 'roi_label', child: text);
    }
    return GestureDetector(
      key: Key('note-move:$roiId'),
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) => _startNote(details.globalPosition, roiId, element.frame),
      onPanUpdate: (details) => _updateNote(details.globalPosition),
      onPanEnd: (_) => _finishNote(),
      onPanCancel: _cancel,
      child: text,
    );
  }

  Widget _connectorLine(PlacedElement element) {
    final start = element.lineStart;
    final end = element.lineEnd;
    if (start == null || end == null) {
      return const SizedBox.shrink();
    }
    const pad = noteArrowWidthPt / 2 + 2;
    final left = math.min(start.x, end.x) - pad;
    final top = math.min(start.y, end.y) - pad;
    final width = (start.x - end.x).abs() + pad * 2;
    final height = (start.y - end.y).abs() + pad * 2;
    return Positioned(
      key: Key('connector:${element.elementId}'),
      left: left,
      top: top,
      width: math.max(width, 1),
      height: math.max(height, 1),
      child: IgnorePointer(
        child: CustomPaint(
          painter: _ConnectorPainter(
            from: Offset(start.x - left, start.y - top),
            to: Offset(end.x - left, end.y - top),
          ),
        ),
      ),
    );
  }

  Widget _maybeSelectFrame(PlacedElement element, Widget child) {
    if (widget.onContainFrameSelected == null || element.kind != 'image_frame') {
      return child;
    }
    return GestureDetector(
      key: Key('frame-select:${element.elementId}'),
      behavior: HitTestBehavior.translucent,
      onTap: () => widget.onContainFrameSelected!(element.elementId),
      child: child,
    );
  }

  Widget _imageChild(PlacedElement element) {
    final content = _imageContent(element);
    final bounds = element.contentRect;
    final selectFrame = widget.onContainFrameSelected != null;
    void select() => widget.onContainFrameSelected!(element.elementId);
    if (widget.onRoiCreated == null ||
        element.fitMode != 'contain' ||
        bounds == null) {
      if (!selectFrame) {
        return content;
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: select,
        child: content,
      );
    }
    return GestureDetector(
      key: Key('roi-create:${element.elementId}'),
      behavior: HitTestBehavior.opaque,
      onTap: selectFrame ? select : null,
      onPanStart: (details) =>
          _startDraft(details.globalPosition, element.elementId),
      onPanUpdate: (details) => _updateDraft(details.globalPosition, bounds),
      onPanEnd: (_) => _finishDraft(),
      onPanCancel: _clearDraft,
      child: content,
    );
  }

  Widget _imageContent(PlacedElement element) {
    final assetPath = element.assetPath;
    if (assetPath == null || assetPath.isEmpty) {
      return const SizedBox.expand();
    }
    if (!_exists(assetPath)) {
      return ColoredBox(
        color: const Color(0xFFF7FAFC),
        child: Center(
          child: Text(
            '${element.displayName}\n画像が見つかりません',
            key: Key('missing:${element.elementId}'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFF2B6CB0)),
          ),
        ),
      );
    }
    final crop = element.crop;
    if (crop == null) {
      return RepaintBoundary(
        child: Image.file(
          File(assetPath),
          fit: BoxFit.fill,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          cacheWidth: 1600,
        ),
      );
    }
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final placement = cropPlacement(
            boxWidth: constraints.maxWidth,
            boxHeight: constraints.maxHeight,
            crop: crop,
          );
          return OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: placement.width,
            maxWidth: placement.width,
            minHeight: placement.height,
            maxHeight: placement.height,
            child: Transform.translate(
              offset: Offset(placement.dx, placement.dy),
            child: RepaintBoundary(
              child: Image.file(
                File(assetPath),
                width: placement.width,
                height: placement.height,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                cacheWidth: 1600,
              ),
            ),
            ),
          );
        },
      ),
    );
  }

  Widget _selectedOverlay(PlacedElement element) {
    return _box(
      key: Key('roi-selected:${element.elementId}'),
      rect: element.frame,
      child: const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.fromBorderSide(
              BorderSide(color: roiFrameColor, width: 3.5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sharedUseMark(PlacedElement element) {
    return _box(
      key: Key('shared-use:${element.elementId}'),
      rect: element.frame,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Color(0x332F855A),
            border: Border.fromBorderSide(
              BorderSide(color: sharedUseColor, width: 3),
            ),
          ),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  sharedUseLabel(widget.highlightedAssetName),
                  key: Key('shared-use-label:${element.elementId}'),
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontSize: 14, color: sharedUseColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectedFrameMark(PlacedElement element) {
    return _box(
      key: Key('selected-frame:${element.elementId}'),
      rect: element.frame,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border.fromBorderSide(
              BorderSide(color: slideFrameColor, width: 3),
            ),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  element.displayName,
                  key: Key('selected-frame-label:${element.elementId}'),
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontSize: 14, color: slideFrameColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _shareTargetMark(PlacedElement element) {
    return _box(
      key: Key('share-target:${element.elementId}'),
      rect: element.frame,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Color(0x336B46C1),
            border: Border.fromBorderSide(
              BorderSide(color: shareTargetColor, width: 3),
            ),
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  shareTargetLabel(
                    widget.highlightedAssetName,
                    displacedName: widget.displacedAssetName,
                  ),
                  key: Key('share-target-label:${element.elementId}'),
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontSize: 14, color: shareTargetColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _box({
    required Key key,
    required SlideRect rect,
    required Widget child,
  }) {
    return Positioned(
      key: key,
      left: rect.x,
      top: rect.y,
      width: rect.width,
      height: rect.height,
      child: child,
    );
  }

  SlideRect? _boundsFor(PlacedElement roi) {
    final sourceId = roi.sourceElementId;
    if (sourceId == null) {
      return null;
    }
    for (final element in widget.result.elements) {
      if (element.elementId == sourceId && element.contentRect != null) {
        return element.contentRect;
      }
    }
    return null;
  }

  Offset? _canvasLocal(Offset global) {
    final box = _canvasContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) {
      return null;
    }
    return box.globalToLocal(global);
  }

  List<Widget> _imageFrameHandles(PlacedElement element) {
    final source = _placedImage(widget.result, element.elementId) ?? element;
    final bounds = imageFrameBounds(widget.result, source);
    final frame = element.frame;
    return [
      for (final handle in FrameHandle.values)
        Positioned(
          key: Key('frame-resize-${handle.name}:${element.elementId}'),
          left: _handleLeft(frame, handle),
          top: _handleTop(frame, handle),
          width: roiHandlePt,
          height: roiHandlePt,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => _startImageResize(details.globalPosition, element, handle),
            onPanUpdate: (details) => _updateImageResize(details.globalPosition, bounds),
            onPanEnd: (_) => _finishImageResize(),
            onPanCancel: _cancelImageResize,
            child: const ColoredBox(color: slideFrameColor),
          ),
        ),
    ];
  }

  PlacedElement? _placedImage(LayoutResult layout, String elementId) {
    for (final element in layout.elements) {
      if (element.elementId == elementId && element.kind == 'image_frame') {
        return element;
      }
    }
    return null;
  }

  double _handleLeft(SlideRect frame, FrameHandle handle) {
    final onRight =
        handle == FrameHandle.right ||
        handle == FrameHandle.topRight ||
        handle == FrameHandle.bottomRight;
    final onCenter =
        handle == FrameHandle.top || handle == FrameHandle.bottom;
    if (onRight) {
      return frame.x + frame.width - roiHandlePt;
    }
    if (onCenter) {
      return frame.x + frame.width / 2 - roiHandlePt / 2;
    }
    return frame.x;
  }

  double _handleTop(SlideRect frame, FrameHandle handle) {
    final onBottom =
        handle == FrameHandle.bottom ||
        handle == FrameHandle.bottomLeft ||
        handle == FrameHandle.bottomRight;
    final onCenter =
        handle == FrameHandle.left || handle == FrameHandle.right;
    if (onBottom) {
      return frame.y + frame.height - roiHandlePt;
    }
    if (onCenter) {
      return frame.y + frame.height / 2 - roiHandlePt / 2;
    }
    return frame.y;
  }

  void _startImageResize(Offset global, PlacedElement element, FrameHandle handle) {
    final local = _canvasLocal(global);
    if (local == null) {
      return;
    }
    _clearDrag();
    _imageResizeId = element.elementId;
    _imageHandle = handle;
    _imageStartLocal = local;
    _imageStartFrame = element.frame;
    _lastImageFrame = element.frame;
  }

  void _updateImageResize(Offset global, SlideRect bounds) {
    final id = _imageResizeId;
    final handle = _imageHandle;
    final startLocal = _imageStartLocal;
    final startFrame = _imageStartFrame;
    final local = _canvasLocal(global);
    if (id == null ||
        handle == null ||
        startLocal == null ||
        startFrame == null ||
        local == null) {
      return;
    }
    final next = resizeFrame(
      startFrame,
      bounds,
      handle,
      local.dx - startLocal.dx,
      local.dy - startLocal.dy,
    );
    _lastImageFrame = next;
    setState(() {
      _liveImageId = id;
      _liveImageFrame = next;
    });
    widget.onImageFrameChanged?.call(id, next);
  }

  void _finishImageResize() {
    final id = _imageResizeId;
    final frame = _lastImageFrame;
    _imageResizeId = null;
    _imageHandle = null;
    _imageStartLocal = null;
    _imageStartFrame = null;
    _lastImageFrame = null;
    setState(() {
      _liveImageId = null;
      _liveImageFrame = null;
    });
    if (id != null && frame != null) {
      widget.onImageFrameCommitted?.call(id, frame);
    }
  }

  void _cancelImageResize() {
    _imageResizeId = null;
    _imageHandle = null;
    _imageStartLocal = null;
    _imageStartFrame = null;
    _lastImageFrame = null;
    setState(() {
      _liveImageId = null;
      _liveImageFrame = null;
    });
  }

  Widget _resizeHandle(
    PlacedElement element,
    SlideRect bounds,
    RoiCorner corner,
  ) {
    final frame = element.frame;
    final onRight =
        corner == RoiCorner.topRight || corner == RoiCorner.bottomRight;
    final onBottom =
        corner == RoiCorner.bottomLeft || corner == RoiCorner.bottomRight;
    return Positioned(
      key: Key(_resizeHandleKey(corner, element.elementId)),
      left: onRight ? frame.x + frame.width - roiHandlePt : frame.x,
      top: onBottom ? frame.y + frame.height - roiHandlePt : frame.y,
      width: roiHandlePt,
      height: roiHandlePt,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) =>
            _startResize(details.globalPosition, frame, corner),
        onPanUpdate: (details) =>
            _updateResize(details.globalPosition, element, bounds),
        onPanEnd: (_) => _finish(element.elementId),
        onPanCancel: _cancel,
        child: const ColoredBox(color: roiFrameColor),
      ),
    );
  }

  String _resizeHandleKey(RoiCorner corner, String roiId) {
    return switch (corner) {
      RoiCorner.topLeft => 'roi-resize-nw:$roiId',
      RoiCorner.topRight => 'roi-resize-ne:$roiId',
      RoiCorner.bottomLeft => 'roi-resize-sw:$roiId',
      RoiCorner.bottomRight => 'roi-resize:$roiId',
    };
  }

  void _startMove(Offset global, SlideRect frame) {
    final local = _canvasLocal(global);
    if (local == null) {
      return;
    }
    _moveGrab = local - Offset(frame.x, frame.y);
    _moveStartFrame = frame;
    _resizeStartLocal = null;
    _resizeStartFrame = null;
    _resizeCorner = null;
    _noteRoiId = null;
    _noteGrab = null;
    _noteStartFrame = null;
    _lastNoteFrame = null;
    _lastFrame = frame;
  }

  void _updateMove(Offset global, PlacedElement element, SlideRect bounds) {
    final grab = _moveGrab;
    final start = _moveStartFrame;
    final local = _canvasLocal(global);
    if (grab == null || start == null || local == null) {
      return;
    }
    final next = clampRoi(
      SlideRect(
        x: local.dx - grab.dx,
        y: local.dy - grab.dy,
        width: start.width,
        height: start.height,
      ),
      bounds,
    );
    _emit(element.elementId, next);
  }

  void _startResize(Offset global, SlideRect frame, RoiCorner corner) {
    final local = _canvasLocal(global);
    if (local == null) {
      return;
    }
    _moveGrab = null;
    _moveStartFrame = null;
    _resizeStartLocal = local;
    _resizeStartFrame = frame;
    _resizeCorner = corner;
    _lastFrame = frame;
  }

  void _updateResize(Offset global, PlacedElement element, SlideRect bounds) {
    final startLocal = _resizeStartLocal;
    final startFrame = _resizeStartFrame;
    final corner = _resizeCorner;
    final local = _canvasLocal(global);
    if (startLocal == null ||
        startFrame == null ||
        corner == null ||
        local == null) {
      return;
    }
    _emit(
      element.elementId,
      resizeRoiFromCorner(
        startFrame,
        bounds,
        corner,
        local.dx - startLocal.dx,
        local.dy - startLocal.dy,
      ),
    );
  }

  void _startNote(Offset global, String roiId, SlideRect frame) {
    final local = _canvasLocal(global);
    if (local == null) {
      return;
    }
    _moveGrab = null;
    _moveStartFrame = null;
    _resizeStartLocal = null;
    _resizeStartFrame = null;
    _resizeCorner = null;
    _lastFrame = null;
    _noteRoiId = roiId;
    _noteGrab = local - Offset(frame.x, frame.y);
    _noteStartFrame = frame;
    _lastNoteFrame = frame;
  }

  void _updateNote(Offset global) {
    final roiId = _noteRoiId;
    final grab = _noteGrab;
    final start = _noteStartFrame;
    final local = _canvasLocal(global);
    if (roiId == null || grab == null || start == null || local == null) {
      return;
    }
    final next = clampRoi(
      SlideRect(
        x: local.dx - grab.dx,
        y: local.dy - grab.dy,
        width: start.width,
        height: start.height,
      ),
      SlideRect(x: 0, y: 0, width: widget.result.slideWidthPt, height: widget.result.slideHeightPt),
    );
    _lastNoteFrame = next;
    setState(() {
      _liveNoteRoiId = roiId;
      _liveNoteFrame = next;
    });
    widget.onNoteFrameChanged?.call(roiId, next);
  }

  void _finishNote() {
    final roiId = _noteRoiId;
    final frame = _lastNoteFrame;
    _noteRoiId = null;
    _noteGrab = null;
    _noteStartFrame = null;
    _lastNoteFrame = null;
    setState(() {
      _liveNoteRoiId = null;
      _liveNoteFrame = null;
    });
    if (roiId != null && frame != null) {
      widget.onNoteFrameCommitted?.call(roiId, frame);
    }
  }

  void _emit(String roiId, SlideRect frame) {
    _lastFrame = frame;
    setState(() {
      _liveRoiId = roiId;
      _liveRoiFrame = frame;
    });
    widget.onRoiFrameChanged?.call(roiId, frame);
  }

  void _finish(String roiId) {
    final frame = _lastFrame;
    _clearDrag();
    setState(() {
      _liveRoiId = null;
      _liveRoiFrame = null;
    });
    if (frame != null) {
      widget.onRoiFrameCommitted?.call(roiId, frame);
    }
  }

  void _cancel() {
    _clearDrag();
    setState(() {
      _liveRoiId = null;
      _liveRoiFrame = null;
      _liveNoteRoiId = null;
      _liveNoteFrame = null;
      _liveImageId = null;
      _liveImageFrame = null;
    });
    _cancelImageResize();
    widget.onRoiEditCancelled?.call();
  }

  bool _exists(String path) {
    final cached = _fileExists[path];
    if (cached != null) {
      return cached;
    }
    final exists = File(path).existsSync();
    _fileExists[path] = exists;
    return exists;
  }

  void _clearDrag() {
    _moveGrab = null;
    _moveStartFrame = null;
    _resizeStartLocal = null;
    _resizeStartFrame = null;
    _resizeCorner = null;
    _lastFrame = null;
    _noteRoiId = null;
    _noteGrab = null;
    _noteStartFrame = null;
    _lastNoteFrame = null;
  }

  void _startDraft(Offset global, String sourceId) {
    final local = _canvasLocal(global);
    if (local == null) {
      return;
    }
    setState(() {
      _draftStart = local;
      _draftSourceId = sourceId;
      _draftFrame = null;
    });
  }

  void _updateDraft(Offset global, SlideRect bounds) {
    final start = _draftStart;
    final local = _canvasLocal(global);
    if (start == null || local == null) {
      return;
    }
    setState(() => _draftFrame = rectInside(start, local, bounds));
  }

  void _finishDraft() {
    final frame = _draftFrame;
    final sourceId = _draftSourceId;
    _clearDraft();
    if (frame == null || sourceId == null || !canCommitRoi(frame)) {
      return;
    }
    widget.onRoiCreated?.call(sourceId, frame);
  }

  void _clearDraft() {
    setState(() {
      _draftStart = null;
      _draftSourceId = null;
      _draftFrame = null;
    });
  }
}

class _ConnectorPainter extends CustomPainter {
  const _ConnectorPainter({required this.from, required this.to});

  final Offset from;
  final Offset to;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = roiFrameColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(from, to, paint);
    final head = arrowHeadPoints(from.dx, from.dy, to.dx, to.dy);
    if (head == null) {
      return;
    }
    final path = Path()
      ..moveTo(head[0].x, head[0].y)
      ..lineTo(head[1].x, head[1].y)
      ..lineTo(head[2].x, head[2].y)
      ..close();
    canvas.drawPath(path, Paint()..color = roiFrameColor);
  }

  @override
  bool shouldRepaint(_ConnectorPainter oldDelegate) {
    return from != oldDelegate.from || to != oldDelegate.to;
  }
}
