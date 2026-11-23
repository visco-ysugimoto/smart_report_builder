import 'dart:io';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/image_library.dart';
import 'package:smart_report_preview/layout_result.dart';

const _zoomColor = Color(0xFFFF0000);

/// 新 UI 向けの軽量なキャンバス。
///
/// LayoutResult を縦横 fit で描画し、画像枠へのクリック選択とライブラリ画像の
/// ドラッグドロップを受ける。右側の役割ドロップダウンは選択中の枠に対して表示する。
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({
    required this.result,
    this.selectedFrameId,
    this.onSelectFrame,
    this.onDropLibraryImage,
    this.onRoleChange,
    this.onZoomSource,
    this.onMoveZoomRegion,
    this.onHeading,
    this.onHeadingPlace,
    this.onHeadingSize,
    this.onTextSize,
    this.onMoveText,
    this.onCaptionHeight,
    this.onTextBody,
    this.onDeleteText,
    this.onResizeFrame,
    super.key,
  });

  final LayoutResult? result;
  final String? selectedFrameId;
  final ValueChanged<String?>? onSelectFrame;
  final Future<void> Function(String frameId, LibraryImage image)? onDropLibraryImage;
  final Future<void> Function(String frameId, String role)? onRoleChange;
  final Future<void> Function(String zoomFrameId, String sourceFrameId)? onZoomSource;
  final Future<void> Function(
    String zoomFrameId,
    double x,
    double y,
    double width,
    double height,
  )? onMoveZoomRegion;
  final Future<void> Function(String frameId, String text)? onHeading;
  final Future<void> Function(String frameId, String place)? onHeadingPlace;
  final Future<void> Function(String frameId, double size)? onHeadingSize;
  final Future<void> Function(String textId, double size)? onTextSize;
  final Future<void> Function(String textId, double x, double y, double width, double height)?
      onMoveText;
  final Future<void> Function(String textId, double height)? onCaptionHeight;
  final Future<void> Function(String textId, String text)? onTextBody;
  final Future<void> Function(String textId)? onDeleteText;
  final Future<void> Function(
    String frameId,
    double x,
    double y,
    double width,
    double height,
  )? onResizeFrame;

  @override
  Widget build(BuildContext context) {
    final current = result;
    if (current == null) {
      return const Center(
        child: Text(
          'プロジェクトを開くと、ここにスライドが出ます',
          key: Key('canvas-placeholder'),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final slideSize = Size(current.slideWidthPt, current.slideHeightPt);
        final scale = _fitScale(constraints.biggest, slideSize);
        final scaledSize = Size(slideSize.width * scale, slideSize.height * scale);
        return Stack(
          children: [
            Center(
              child: SizedBox(
                width: scaledSize.width,
                height: scaledSize.height,
                child: _SlideBoard(
                  result: current,
                  scale: scale,
                  selectedFrameId: selectedFrameId,
                  onSelectFrame: (id) {
                    onSelectFrame?.call(id);
                  },
                  onDropLibraryImage: onDropLibraryImage,
                  onMoveZoomRegion: onMoveZoomRegion,
                  onMoveText: onMoveText,
                  onCaptionHeight: onCaptionHeight,
                  onResizeFrame: onResizeFrame,
                ),
              ),
            ),
            if (_selectedElement(current) case final selected? when selected.roleId != 'caption')
              Positioned(
                right: 12,
                top: 12,
                child: selected.kind == 'text'
                    ? _TextInspector(
                            element: selected,
                            onTextBody: onTextBody,
                            onTextSize: onTextSize,
                            onMoveText: onMoveText,
                            onDeleteText: onDeleteText,
                            onClose: () => onSelectFrame?.call(null),
                          )
                    : _FrameInspector(
                        frame: selected,
                        sourceFrames: [
                          for (final element in current.elements)
                            if (element.kind == 'image_frame' && element.fitMode == 'contain') element,
                        ],
                        onRoleChange: onRoleChange,
                        onZoomSource: onZoomSource,
                        onHeading: onHeading,
                        onHeadingPlace: onHeadingPlace,
                        onHeadingSize: onHeadingSize,
                        onResizeFrame: onResizeFrame,
                        onClose: () => onSelectFrame?.call(null),
                      ),
              ),
            if (current.violations.isNotEmpty)
              Positioned(
                left: 8,
                top: 8,
                child: _ViolationBadge(
                  violations: current.violations,
                  elements: current.elements,
                  color: scheme.error,
                  onSelect: onSelectFrame,
                ),
              ),
          ],
        );
      },
    );
  }

  PlacedElement? _selectedElement(LayoutResult r) {
    if (selectedFrameId == null) return null;
    for (final element in r.elements) {
      if (element.elementId == selectedFrameId &&
          (element.kind == 'image_frame' || element.kind == 'text')) {
        return element;
      }
    }
    return null;
  }

  double _fitScale(Size viewport, Size slide) {
    if (viewport.width <= 0 || viewport.height <= 0 || slide.width <= 0 || slide.height <= 0) {
      return 1;
    }
    return (viewport.width / slide.width).clamp(0.05, 4.0).toDouble().clamp(
          0.05,
          viewport.height / slide.height,
        );
  }
}

class _SlideBoard extends StatefulWidget {
  const _SlideBoard({
    required this.result,
    required this.scale,
    required this.selectedFrameId,
    required this.onSelectFrame,
    required this.onDropLibraryImage,
    required this.onMoveZoomRegion,
    required this.onMoveText,
    required this.onCaptionHeight,
    required this.onResizeFrame,
  });

  final LayoutResult result;
  final double scale;
  final String? selectedFrameId;
  final ValueChanged<String?> onSelectFrame;
  final Future<void> Function(String frameId, LibraryImage image)? onDropLibraryImage;
  final Future<void> Function(
    String zoomFrameId,
    double x,
    double y,
    double width,
    double height,
  )? onMoveZoomRegion;
  final Future<void> Function(String textId, double x, double y, double width, double height)?
      onMoveText;
  final Future<void> Function(String textId, double height)? onCaptionHeight;
  final Future<void> Function(
    String frameId,
    double x,
    double y,
    double width,
    double height,
  )? onResizeFrame;

  @override
  State<_SlideBoard> createState() => _SlideBoardState();
}

class _SlideBoardState extends State<_SlideBoard> {
  String? _dragZoomId;
  double? _dragX;
  double? _dragY;
  double? _dragW;
  double? _dragH;
  String? _dragTextId;
  double? _textX;
  double? _textY;
  double? _textW;
  double? _textH;
  String? _dragPictureId;
  double? _picX;
  double? _picY;
  double? _picW;
  double? _picH;
  bool _saving = false;

  LayoutResult get result => widget.result;
  double get scale => widget.scale;
  String? get selectedFrameId => widget.selectedFrameId;
  ValueChanged<String?> get onSelectFrame => widget.onSelectFrame;
  Future<void> Function(String textId, double height)? get onCaptionHeight => widget.onCaptionHeight;
  Future<void> Function(String frameId, LibraryImage image)? get onDropLibraryImage =>
      widget.onDropLibraryImage;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
        onSelectFrame(null);
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            if (result.chromeImage != null && result.chromeImage!.isNotEmpty)
              Positioned.fill(
                child: Image.file(
                  File(result.chromeImage!),
                  fit: BoxFit.fill,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                if (result.titleText != null && result.titleFrame != null)
              _positioned(
                result.titleFrame!,
                child: IgnorePointer(
                  child: Text(
                    result.titleText!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: (result.titleFontPt ?? 18) * scale,
                      height: 1.1,
                      color: _hex(result.titleColor),
                    ),
                  ),
                ),
              ),
            for (final element in result.elements)
              ..._renderElement(context, element),
          ],
        ),
      ),
    );
  }

  List<Widget> _renderElement(BuildContext context, PlacedElement element) {
    switch (element.kind) {
      case 'image_frame':
        return _frame(context, element);
      case 'text':
        return [_text(context, element)];
      case 'table':
        return [_table(context, element)];
      case 'roi':
        return [_roi(element)];
      default:
        return const [];
    }
  }

  List<Widget> _frame(BuildContext context, PlacedElement element) {
    final scheme = Theme.of(context).colorScheme;
    final selected = element.elementId == selectedFrameId;
    final hasImage = element.contentRect != null && element.assetPath != null;
    final child = DragTarget<LibraryImage>(
      onWillAcceptWithDetails: (_) => element.fitMode == 'contain',
      onAcceptWithDetails: (details) async {
        await onDropLibraryImage?.call(element.elementId, details.data);
      },
      builder: (context, candidate, rejected) {
        final isHovering = candidate.isNotEmpty;
        if (hasImage && !isHovering) return const SizedBox.expand();
        return GestureDetector(
          onTap: () => onSelectFrame(element.elementId),
          child: Container(
            decoration: BoxDecoration(
              color: isHovering
                  ? scheme.primaryContainer.withValues(alpha: 0.3)
                  : scheme.surfaceContainerLow,
              border: Border.all(
                color: isHovering ? scheme.primary : scheme.outline.withValues(alpha: 0.6),
                width: isHovering ? 2 : 1,
              ),
            ),
            child: hasImage
                ? null
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            element.fitMode == 'roi'
                                ? Icons.center_focus_strong
                                : Icons.image_outlined,
                            size: 18,
                            color: scheme.outline,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            element.fitMode == 'roi' ? '拡大元を選択' : element.displayName,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        );
      },
    );
    final widgets = <Widget>[_positioned(element.frame, child: child)];
    if (hasImage) widgets.add(_picture(context, element, selected));
    final label = _shownLabel(element);
    final heading = (element.renderedText ?? element.text ?? '').trim();
    if (label != null && heading.isNotEmpty) {
      widgets.add(
        _positioned(
          label,
          child: Text(
            heading,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: element.textAnchor == 'below' ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: (element.fontPt ?? 14) * scale,
              fontWeight: FontWeight.w700,
              height: 1.1,
              color: scheme.onSurface,
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _picture(BuildContext context, PlacedElement element, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    final box = Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline.withValues(alpha: 0.45),
          width: selected ? 2 : 1,
        ),
      ),
      child: element.fitMode == 'roi' && _shownCrop(element) != null
          ? _CroppedImage(path: element.assetPath!, crop: _shownCrop(element)!)
          : Image.file(
              File(element.assetPath!),
              fit: BoxFit.fill,
              cacheWidth: 1200,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
    );
    return _positioned(
      _pictureBox(element),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => onSelectFrame(element.elementId),
              onPanStart: element.groupFrame == null ? null : (_) => _beginPicture(element),
              onPanUpdate: (details) => _movePicture(details.delta),
              onPanEnd: (_) => _commitPicture(),
              onPanCancel: _commitPicture,
              child: MouseRegion(
                cursor: element.groupFrame == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.move,
                child: box,
              ),
            ),
          ),
          if (selected && element.groupFrame != null)
            for (final handle in const [
              (horizontal: -1, vertical: 0),
              (horizontal: 1, vertical: 0),
              (horizontal: 0, vertical: -1),
              (horizontal: 0, vertical: 1),
              (horizontal: -1, vertical: -1),
              (horizontal: 1, vertical: -1),
              (horizontal: 1, vertical: 1),
              (horizontal: -1, vertical: 1),
            ])
              _pictureHandle(element, handle.horizontal, handle.vertical),
        ],
      ),
    );
  }

  SlideRect _pictureBox(PlacedElement element) {
    if (_dragPictureId == element.elementId &&
        _picX != null &&
        _picY != null &&
        _picW != null &&
        _picH != null) {
      return SlideRect(x: _picX!, y: _picY!, width: _picW!, height: _picH!);
    }
    return pictureBox(element);
  }

  void _beginPicture(PlacedElement element) {
    if (_saving || element.groupFrame == null) return;
    final box = pictureBox(element);
    setState(() {
      _dragPictureId = element.elementId;
      _picX = box.x;
      _picY = box.y;
      _picW = box.width;
      _picH = box.height;
    });
    onSelectFrame(element.elementId);
  }

  void _movePicture(Offset delta) {
    final element = _draggedPicture();
    if (_saving || element == null || element.groupFrame == null) return;
    final next = movePicture(
      SlideRect(x: _picX!, y: _picY!, width: _picW!, height: _picH!),
      element.groupFrame!,
      delta.dx / scale,
      delta.dy / scale,
    );
    setState(() {
      _picX = next.x;
      _picY = next.y;
      _picW = next.width;
      _picH = next.height;
    });
  }

  Widget _pictureHandle(PlacedElement element, int horizontal, int vertical) {
    const size = 12.0;
    return Align(
      alignment: Alignment(horizontal.toDouble(), vertical.toDouble()),
      child: MouseRegion(
        cursor: _resizeCursor(horizontal, vertical),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _beginPicture(element),
          onPanUpdate: (details) => _resizePicture(details.delta, horizontal, vertical),
          onPanEnd: (_) => _commitPicture(),
          onPanCancel: _commitPicture,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
            ),
          ),
        ),
      ),
    );
  }

  void _resizePicture(Offset delta, int horizontal, int vertical) {
    final element = _draggedPicture();
    if (_saving || element == null || element.groupFrame == null) return;
    final next = resizePicture(
      SlideRect(x: _picX!, y: _picY!, width: _picW!, height: _picH!),
      element.groupFrame!,
      dx: delta.dx / scale,
      dy: delta.dy / scale,
      horizontal: horizontal,
      vertical: vertical,
    );
    setState(() {
      _picX = next.x;
      _picY = next.y;
      _picW = next.width;
      _picH = next.height;
    });
  }

  PlacedElement? _draggedPicture() {
    final id = _dragPictureId;
    if (id == null || _picX == null) return null;
    for (final element in result.elements) {
      if (element.elementId == id) return element;
    }
    return null;
  }

  SlideRect? _shownLabel(PlacedElement element) {
    final label = element.labelFrame;
    if (label == null) return null;
    if (_dragPictureId != element.elementId || _picX == null || _picY == null) return label;
    final origin = pictureBox(element);
    final picture = SlideRect(x: _picX!, y: _picY!, width: _picW!, height: _picH!);
    final moved = (picture.width - origin.width).abs() < 0.5 &&
        (picture.height - origin.height).abs() < 0.5;
    if (moved) {
      return SlideRect(
        x: label.x + picture.x - origin.x,
        y: label.y + picture.y - origin.y,
        width: label.width,
        height: label.height,
      );
    }
    final below = element.textAnchor == 'below';
    return SlideRect(
      x: picture.x,
      y: below ? picture.y + picture.height : picture.y - label.height,
      width: picture.width,
      height: label.height,
    );
  }

  Future<void> _commitPicture() async {
    final element = _draggedPicture();
    final group = element?.groupFrame;
    if (_saving || element == null || group == null || _picX == null) return;
    final picture = SlideRect(x: _picX!, y: _picY!, width: _picW!, height: _picH!);
    final origin = pictureBox(element);
    final moved = (picture.width - origin.width).abs() < 0.5 &&
        (picture.height - origin.height).abs() < 0.5;
    final slot = moved
        ? movePicture(frameSlot(element), group, picture.x - origin.x, picture.y - origin.y)
        : movePicture(slotAroundPicture(picture, element), group, 0, 0);
    final normalized = normalizePicture(slot, group);
    _saving = true;
    try {
      await widget.onResizeFrame?.call(
        element.elementId,
        normalized.x,
        normalized.y,
        normalized.width,
        normalized.height,
      );
    } finally {
      if (mounted) {
        setState(() {
          _dragPictureId = null;
          _picX = null;
          _picY = null;
          _picW = null;
          _picH = null;
          _saving = false;
        });
      }
    }
  }

  Widget _text(BuildContext context, PlacedElement element) {
    final text = (element.text ?? '').trim();
    final scheme = Theme.of(context).colorScheme;
    final frame = _textFrame(element);
    final movable = element.roleId == 'note';
    final caption = element.roleId == 'caption';
    final selected = (movable || caption) && element.elementId == selectedFrameId;
    final box = Container(
      padding: EdgeInsets.all(6 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Text(
        text.isEmpty ? '（説明文・展開時に自動挿入されます）' : text,
        style: TextStyle(
          fontSize: (element.fontPt ?? 16) * scale,
          color: text.isEmpty ? scheme.outline : scheme.onSurface,
          fontStyle: text.isEmpty ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
    if (caption) {
      return _positioned(
        frame,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => onSelectFrame(element.elementId),
                child: box,
              ),
            ),
            if (selected && onCaptionHeight != null)
              for (final vertical in const [-1, 1])
                _textResizeHandle(element, 0, vertical, caption: true),
          ],
        ),
      );
    }
    if (!movable) {
      return _positioned(frame, child: box);
    }
    return _positioned(
      frame,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => onSelectFrame(element.elementId),
              onPanStart: (_) => _beginTextDrag(element),
              onPanUpdate: (details) => _dragText(details.delta),
              onPanEnd: (_) => _commitTextDrag(),
              onPanCancel: _commitTextDrag,
              child: MouseRegion(cursor: SystemMouseCursors.move, child: box),
            ),
          ),
          if (selected)
            for (final handle in const [
              (horizontal: -1, vertical: 0),
              (horizontal: 1, vertical: 0),
              (horizontal: 0, vertical: -1),
              (horizontal: 0, vertical: 1),
              (horizontal: -1, vertical: -1),
              (horizontal: 1, vertical: -1),
              (horizontal: 1, vertical: 1),
              (horizontal: -1, vertical: 1),
            ])
              _textResizeHandle(element, handle.horizontal, handle.vertical),
        ],
      ),
    );
  }

  SlideRect _textFrame(PlacedElement element) {
    if (_dragTextId != element.elementId ||
        _textX == null ||
        _textY == null ||
        _textW == null ||
        _textH == null) {
      return element.frame;
    }
    return SlideRect(x: _textX!, y: _textY!, width: _textW!, height: _textH!);
  }

  void _beginTextDrag(PlacedElement element) {
    if (_saving) return;
    final frame = element.frame;
    setState(() {
      _dragTextId = element.elementId;
      _textX = frame.x;
      _textY = frame.y;
      _textW = frame.width;
      _textH = frame.height;
    });
    onSelectFrame(element.elementId);
  }

  void _dragText(Offset delta) {
    if (_saving || _textX == null || _textY == null) return;
    setState(() {
      _textX = _textX! + delta.dx / scale;
      _textY = _textY! + delta.dy / scale;
    });
  }

  Widget _textResizeHandle(
    PlacedElement element,
    int horizontal,
    int vertical, {
    bool caption = false,
  }) {
    const size = 12.0;
    return Align(
      alignment: Alignment(horizontal.toDouble(), vertical.toDouble()),
      child: MouseRegion(
        cursor: _resizeCursor(horizontal, vertical),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _beginTextDrag(element),
          onPanUpdate: (details) => _resizeText(details.delta, horizontal, vertical),
          onPanEnd: (_) => caption ? _commitCaptionHeight() : _commitTextDrag(),
          onPanCancel: caption ? _commitCaptionHeight : _commitTextDrag,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
            ),
          ),
        ),
      ),
    );
  }

  void _resizeText(Offset delta, int horizontal, int vertical) {
    if (_saving || _textX == null || _textY == null || _textW == null || _textH == null) return;
    setState(() {
      var x = _textX!;
      var y = _textY!;
      var width = _textW!;
      var height = _textH!;
      final dx = delta.dx / scale;
      final dy = delta.dy / scale;
      if (horizontal < 0) {
        x += dx;
        width -= dx;
      } else if (horizontal > 0) {
        width += dx;
      }
      if (vertical < 0) {
        y += dy;
        height -= dy;
      } else if (vertical > 0) {
        height += dy;
      }
      if (width < _minTextWidth) {
        if (horizontal < 0) x -= _minTextWidth - width;
        width = _minTextWidth;
      }
      if (height < _minTextHeight) {
        if (vertical < 0) y -= _minTextHeight - height;
        height = _minTextHeight;
      }
      _textX = x;
      _textY = y;
      _textW = width;
      _textH = height;
    });
  }

  Future<void> _commitCaptionHeight() async {
    final id = _dragTextId;
    final height = _textH;
    if (_saving || id == null || height == null) return;
    _saving = true;
    try {
      await widget.onCaptionHeight?.call(id, height);
    } finally {
      if (mounted) {
        setState(() {
          _dragTextId = null;
          _textX = null;
          _textY = null;
          _textW = null;
          _textH = null;
          _saving = false;
        });
      }
    }
  }

  Future<void> _commitTextDrag() async {
    final id = _dragTextId;
    final x = _textX;
    final y = _textY;
    final width = _textW;
    final height = _textH;
    if (_saving || id == null || x == null || y == null || width == null || height == null) {
      return;
    }
    _saving = true;
    try {
      await widget.onMoveText?.call(id, x, y, width, height);
    } finally {
      if (mounted) {
        setState(() {
          _dragTextId = null;
          _textX = null;
          _textY = null;
          _textW = null;
          _textH = null;
          _saving = false;
        });
      }
    }
  }

  Widget _table(BuildContext context, PlacedElement element) {
    final rows = element.tableRows ?? const <List<String>>[];
    return _positioned(
      element.frame,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            for (final row in rows)
              Expanded(
                child: Row(
                  children: [
                    for (final cell in row)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Text(
                            cell,
                            style: TextStyle(fontSize: 10 * scale),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _roi(PlacedElement element) {
    final movable = element.zoomElementId != null && element.zoomElementId == selectedFrameId;
    final frame = _roiFrame(element);
    final box = Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: _zoomColor,
          width: movable ? 2.5 : 1.5,
        ),
      ),
    );
    if (!movable) {
      return _positioned(frame, child: IgnorePointer(child: box));
    }
    return _positioned(
      frame,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                onPanStart: (_) => _beginDrag(element),
                onPanUpdate: (details) => _dragBy(element, details.delta),
                onPanEnd: (_) => _commitDrag(),
                onPanCancel: _commitDrag,
                child: box,
              ),
            ),
          ),
          for (final handle in const [
            (horizontal: -1, vertical: -1),
            (horizontal: 0, vertical: -1),
            (horizontal: 1, vertical: -1),
            (horizontal: 1, vertical: 0),
            (horizontal: 1, vertical: 1),
            (horizontal: 0, vertical: 1),
            (horizontal: -1, vertical: 1),
            (horizontal: -1, vertical: 0),
          ])
            _resizeHandle(element, handle.horizontal, handle.vertical),
        ],
      ),
    );
  }

  Widget _resizeHandle(PlacedElement element, int horizontal, int vertical) {
    const size = 12.0;
    return Align(
      alignment: Alignment(horizontal.toDouble(), vertical.toDouble()),
      child: MouseRegion(
        cursor: _resizeCursor(horizontal, vertical),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _beginDrag(element),
          onPanUpdate: (details) => _resizeBy(element, details.delta, horizontal, vertical),
          onPanEnd: (_) => _commitDrag(),
          onPanCancel: _commitDrag,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _zoomColor, width: 2),
            ),
          ),
        ),
      ),
    );
  }

  MouseCursor _resizeCursor(int horizontal, int vertical) {
    if (horizontal == 0) return SystemMouseCursors.resizeUpDown;
    if (vertical == 0) return SystemMouseCursors.resizeLeftRight;
    if (horizontal == vertical) return SystemMouseCursors.resizeUpLeftDownRight;
    return SystemMouseCursors.resizeUpRightDownLeft;
  }

  SlideRect? _shownCrop(PlacedElement element) {
    final crop = element.crop;
    if (crop == null ||
        _dragZoomId == null ||
        _dragX == null ||
        _dragY == null ||
        _dragW == null ||
        _dragH == null) {
      return crop;
    }
    final matches = element.kind == 'roi'
        ? element.zoomElementId == _dragZoomId
        : element.elementId == _dragZoomId;
    if (!matches) return crop;
    return SlideRect(x: _dragX!, y: _dragY!, width: _dragW!, height: _dragH!);
  }

  SlideRect _roiFrame(PlacedElement element) {
    final crop = _shownCrop(element);
    final source = _contentOf(element.sourceElementId);
    if (crop == null || source == null || crop == element.crop) return element.frame;
    return SlideRect(
      x: source.x + crop.x * source.width,
      y: source.y + crop.y * source.height,
      width: crop.width * source.width,
      height: crop.height * source.height,
    );
  }

  SlideRect? _contentOf(String? elementId) {
    if (elementId == null) return null;
    for (final element in result.elements) {
      if (element.elementId == elementId && element.kind == 'image_frame') {
        return element.contentRect ?? element.frame;
      }
    }
    return null;
  }

  void _beginDrag(PlacedElement element) {
    final crop = element.crop;
    if (_saving || crop == null || element.zoomElementId == null) return;
    setState(() {
      _dragZoomId = element.zoomElementId;
      _dragX = crop.x;
      _dragY = crop.y;
      _dragW = crop.width;
      _dragH = crop.height;
    });
  }

  void _dragBy(PlacedElement element, Offset delta) {
    final crop = element.crop;
    final source = _contentOf(element.sourceElementId);
    if (_saving || crop == null || source == null || source.width <= 0 || source.height <= 0) {
      return;
    }
    final width = _dragW ?? crop.width;
    final height = _dragH ?? crop.height;
    final x = _clampOrigin((_dragX ?? crop.x) + delta.dx / scale / source.width, width);
    final y = _clampOrigin((_dragY ?? crop.y) + delta.dy / scale / source.height, height);
    setState(() {
      _dragZoomId = element.zoomElementId;
      _dragX = x;
      _dragY = y;
      _dragW = width;
      _dragH = height;
    });
  }

  void _resizeBy(PlacedElement element, Offset delta, int horizontal, int vertical) {
    final crop = element.crop;
    final source = _contentOf(element.sourceElementId);
    if (_saving || crop == null || source == null || source.width <= 0 || source.height <= 0) {
      return;
    }
    final dx = delta.dx / scale / source.width;
    final dy = delta.dy / scale / source.height;
    var x = _dragX ?? crop.x;
    var y = _dragY ?? crop.y;
    var width = _dragW ?? crop.width;
    var height = _dragH ?? crop.height;
    if (horizontal < 0) {
      final left = (x + dx).clamp(0.0, x + width - _minZoomSize);
      width = x + width - left;
      x = left;
    } else if (horizontal > 0) {
      width = (width + dx).clamp(_minZoomSize, 1 - x);
    }
    if (vertical < 0) {
      final top = (y + dy).clamp(0.0, y + height - _minZoomSize);
      height = y + height - top;
      y = top;
    } else if (vertical > 0) {
      height = (height + dy).clamp(_minZoomSize, 1 - y);
    }
    setState(() {
      _dragZoomId = element.zoomElementId;
      _dragX = x;
      _dragY = y;
      _dragW = width;
      _dragH = height;
    });
  }

  Future<void> _commitDrag() async {
    final zoomId = _dragZoomId;
    final x = _dragX;
    final y = _dragY;
    final width = _dragW;
    final height = _dragH;
    if (_saving || zoomId == null || x == null || y == null || width == null || height == null) {
      return;
    }
    _saving = true;
    try {
      await widget.onMoveZoomRegion?.call(zoomId, x, y, width, height);
    } finally {
      if (mounted) {
        setState(() {
          _dragZoomId = null;
          _dragX = null;
          _dragY = null;
          _dragW = null;
          _dragH = null;
          _saving = false;
        });
      }
    }
  }

  double _clampOrigin(double value, double size) {
    final limit = (1 - size).clamp(0.0, 1.0);
    return value.clamp(0.0, limit);
  }

  static const double _minZoomSize = 0.02;
  static const double _minTextWidth = 48;
  static const double _minTextHeight = 24;

  Widget _positioned(SlideRect rect, {required Widget child}) {
    return Positioned(
      left: rect.x * scale,
      top: rect.y * scale,
      width: rect.width * scale,
      height: rect.height * scale,
      child: child,
    );
  }

  Color _hex(String? value) {
    if (value == null || value.length != 7 || !value.startsWith('#')) {
      return const Color(0xFF1F2A44);
    }
    final rgb = int.tryParse(value.substring(1), radix: 16);
    if (rgb == null) return const Color(0xFF1F2A44);
    return Color(0xFF000000 | rgb);
  }
}

class _CroppedImage extends StatelessWidget {
  const _CroppedImage({required this.path, required this.crop});

  final String path;
  final SlideRect crop;

  @override
  Widget build(BuildContext context) {
    final widthFactor = crop.width <= 0 ? 1.0 : crop.width;
    final heightFactor = crop.height <= 0 ? 1.0 : crop.height;
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fullWidth = constraints.maxWidth / widthFactor;
          final fullHeight = constraints.maxHeight / heightFactor;
          return OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: fullWidth,
            maxWidth: fullWidth,
            minHeight: fullHeight,
            maxHeight: fullHeight,
            child: Transform.translate(
              offset: Offset(-crop.x * fullWidth, -crop.y * fullHeight),
              child: Image.file(
                File(path),
                width: fullWidth,
                height: fullHeight,
                fit: BoxFit.fill,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FrameInspector extends StatelessWidget {
  const _FrameInspector({
    required this.frame,
    required this.sourceFrames,
    required this.onRoleChange,
    required this.onZoomSource,
    required this.onHeading,
    required this.onHeadingPlace,
    required this.onHeadingSize,
    required this.onResizeFrame,
    required this.onClose,
  });

  final PlacedElement frame;
  final List<PlacedElement> sourceFrames;
  final Future<void> Function(String frameId, String role)? onRoleChange;
  final Future<void> Function(String zoomFrameId, String sourceFrameId)? onZoomSource;
  final Future<void> Function(String frameId, String text)? onHeading;
  final Future<void> Function(String frameId, String place)? onHeadingPlace;
  final Future<void> Function(String frameId, double size)? onHeadingSize;
  final Future<void> Function(
    String frameId,
    double x,
    double y,
    double width,
    double height,
  )? onResizeFrame;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentRole = _currentRole(frame);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      color: Colors.white,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    frame.displayName,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                ),
              ],
            ),
            if (frame.assetPath != null && frame.groupFrame != null) ...[
              const SizedBox(height: 8),
              _PictureSizeRow(frame: frame, onResizeFrame: onResizeFrame),
              const SizedBox(height: 4),
              Text(
                'ドラッグで移動、角で拡大・縮小',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 8),
            Text('種類', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              key: const Key('frame-role-dropdown'),
              initialValue: currentRole,
              decoration: const InputDecoration(isDense: true),
              items: const [
                DropdownMenuItem(value: 'image', child: Text('画像')),
                DropdownMenuItem(value: 'zoom', child: Text('拡大画像')),
              ],
              onChanged: (role) {
                if (role != null && role != currentRole) {
                  onRoleChange?.call(frame.elementId, role);
                }
              },
            ),
            const SizedBox(height: 10),
            Text('見出し', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            _CommitTextField(
              fieldKey: Key('frame-heading:${frame.elementId}:${frame.text}'),
              initialValue: frame.text ?? '',
              hint: '例: {comment} {index}',
              onCommit: (value) => onHeading?.call(frame.elementId, value),
            ),
            const SizedBox(height: 4),
            Text(
              '{page} {index} {n} {comment}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: Key('frame-heading-place:${frame.elementId}:${frame.textAnchor}'),
              initialValue: frame.textAnchor == 'below' ? 'below' : 'above',
              decoration: const InputDecoration(isDense: true),
              items: const [
                DropdownMenuItem(value: 'above', child: Text('画像の上')),
                DropdownMenuItem(value: 'below', child: Text('画像の下中央')),
              ],
              onChanged: (place) {
                if (place != null && place != (frame.textAnchor == 'below' ? 'below' : 'above')) {
                  onHeadingPlace?.call(frame.elementId, place);
                }
              },
            ),
            const SizedBox(height: 8),
            Text('見出しのサイズ', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            _SizeDropdown(
              fieldKey: Key('frame-heading-size:${frame.elementId}:${frame.fontPt}'),
              value: (frame.fontPt ?? 14).round(),
              onChanged: (size) => onHeadingSize?.call(frame.elementId, size.toDouble()),
            ),
            if (currentRole == 'zoom') ...[
              const SizedBox(height: 10),
              Text('拡大元', style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
              if (sourceFrames.isEmpty)
                Text(
                  '通常の画像枠がありません',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                )
              else
                DropdownButtonFormField<String>(
                  key: Key('zoom-source:${frame.elementId}:${frame.sourceElementId}'),
                  initialValue: sourceFrames.any((item) => item.elementId == frame.sourceElementId)
                      ? frame.sourceElementId
                      : null,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '拡大する枠',
                  ),
                  items: [
                    for (final source in sourceFrames)
                      DropdownMenuItem(
                        value: source.elementId,
                        child: Text(source.displayName),
                      ),
                  ],
                  onChanged: (sourceId) {
                    if (sourceId != null && sourceId != frame.sourceElementId) {
                      onZoomSource?.call(frame.elementId, sourceId);
                    }
                  },
                ),
              const SizedBox(height: 8),
              Text(
                '赤枠の内側で移動、辺や角で大きさを変えられます',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            if (frame.assetPath != null) ...[
              const SizedBox(height: 10),
              Text(
                '割当: ${_fileName(frame.assetPath!)}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _currentRole(PlacedElement frame) {
    if (frame.fitMode == 'roi') return 'zoom';
    return 'image';
  }

  String _fileName(String path) {
    final sep = path.lastIndexOf(RegExp(r'[\\/]'));
    return sep < 0 ? path : path.substring(sep + 1);
  }
}

class _PictureSizeRow extends StatelessWidget {
  const _PictureSizeRow({required this.frame, required this.onResizeFrame});

  final PlacedElement frame;
  final Future<void> Function(String frameId, double x, double y, double width, double height)?
      onResizeFrame;

  @override
  Widget build(BuildContext context) {
    final group = frame.groupFrame;
    return Row(
      children: [
        Expanded(
          child: _SizeButton(
            buttonKey: Key('frame-fit:${frame.elementId}'),
            label: '合わせる',
            onPressed: group == null || onResizeFrame == null
                ? null
                : () => _apply(pictureBox(frame), group),
          ),
        ),
        const SizedBox(width: 4),
        _SizeButton(
          buttonKey: Key('frame-smaller:${frame.elementId}'),
          label: '縮小',
          onPressed: group == null || onResizeFrame == null
              ? null
              : () => _apply(scalePicture(pictureBox(frame), group, 0.87), group),
        ),
        const SizedBox(width: 4),
        _SizeButton(
          buttonKey: Key('frame-larger:${frame.elementId}'),
          label: '拡大',
          onPressed: group == null || onResizeFrame == null
              ? null
              : () => _apply(scalePicture(pictureBox(frame), group, 1.15), group),
        ),
      ],
    );
  }

  void _apply(SlideRect box, SlideRect group) {
    final slot = movePicture(slotAroundPicture(box, frame), group, 0, 0);
    final normalized = normalizePicture(slot, group);
    onResizeFrame?.call(
      frame.elementId,
      normalized.x,
      normalized.y,
      normalized.width,
      normalized.height,
    );
  }
}

class _SizeButton extends StatelessWidget {
  const _SizeButton({required this.buttonKey, required this.label, required this.onPressed});

  final Key buttonKey;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: buttonKey,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

class _TextInspector extends StatelessWidget {
  const _TextInspector({
    required this.element,
    required this.onTextBody,
    required this.onTextSize,
    required this.onMoveText,
    required this.onDeleteText,
    required this.onClose,
  });

  final PlacedElement element;
  final Future<void> Function(String textId, String text)? onTextBody;
  final Future<void> Function(String textId, double size)? onTextSize;
  final Future<void> Function(String textId, double x, double y, double width, double height)?
      onMoveText;
  final Future<void> Function(String textId)? onDeleteText;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      color: Colors.white,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('テキスト')),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _CommitTextField(
              fieldKey: Key('free-text:${element.elementId}:${element.text}'),
              initialValue: element.text ?? '',
              hint: 'テキスト',
              onCommit: (value) => onTextBody?.call(element.elementId, value),
            ),
            const SizedBox(height: 8),
            Text('文字サイズ', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            _SizeDropdown(
              fieldKey: Key('free-text-size:${element.elementId}:${element.fontPt}'),
              value: (element.fontPt ?? 16).round(),
              onChanged: (size) => onTextSize?.call(element.elementId, size.toDouble()),
            ),
            const SizedBox(height: 8),
            Text('枠の幅', style: Theme.of(context).textTheme.labelSmall),
            _WidthSlider(
              fieldKey: Key('free-text-width:${element.elementId}:${element.frame.width.round()}'),
              width: element.frame.width,
              onCommit: onMoveText == null
                  ? null
                  : (width) => onMoveText!.call(
                        element.elementId,
                        element.frame.x,
                        element.frame.y,
                        width,
                        element.frame.height,
                      ),
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: Key('free-text-delete:${element.elementId}'),
              onPressed: onDeleteText == null ? null : () => onDeleteText!.call(element.elementId),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('このテキストを削除'),
            ),
            const SizedBox(height: 8),
            Text(
              '枠の中をドラッグすると移動、辺や角で幅と高さを変えられます',
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _WidthSlider extends StatefulWidget {
  const _WidthSlider({required this.fieldKey, required this.width, required this.onCommit});

  final Key fieldKey;
  final double width;
  final ValueChanged<double>? onCommit;

  @override
  State<_WidthSlider> createState() => _WidthSliderState();
}

class _WidthSliderState extends State<_WidthSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = (_dragging ?? widget.width).clamp(48.0, 520.0);
    return Slider(
      key: widget.fieldKey,
      min: 48,
      max: 520,
      value: value,
      label: '${value.round()} pt',
      onChanged: widget.onCommit == null
          ? null
          : (next) => setState(() => _dragging = next),
      onChangeEnd: widget.onCommit == null
          ? null
          : (next) {
              setState(() => _dragging = null);
              widget.onCommit!(next);
            },
    );
  }
}

const _textSizes = [12, 14, 16, 18, 22, 28, 36];

class _SizeDropdown extends StatelessWidget {
  const _SizeDropdown({
    required this.fieldKey,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = _textSizes.contains(value) ? value : 16;
    return DropdownButtonFormField<int>(
      key: fieldKey,
      initialValue: selected,
      decoration: const InputDecoration(isDense: true),
      items: [
        for (final size in _textSizes)
          DropdownMenuItem(value: size, child: Text('$size pt')),
      ],
      onChanged: (next) {
        if (next != null && next != selected) onChanged(next);
      },
    );
  }
}

class _CommitTextField extends StatefulWidget {
  const _CommitTextField({
    required this.fieldKey,
    required this.initialValue,
    required this.hint,
    required this.onCommit,
  });

  final Key fieldKey;
  final String initialValue;
  final String hint;
  final ValueChanged<String> onCommit;

  @override
  State<_CommitTextField> createState() => _CommitTextFieldState();
}

class _CommitTextFieldState extends State<_CommitTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);

  @override
  void didUpdateWidget(covariant _CommitTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue && _controller.text != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: widget.fieldKey,
      controller: _controller,
      decoration: InputDecoration(isDense: true, hintText: widget.hint),
      onSubmitted: widget.onCommit,
      onTapOutside: (_) => widget.onCommit(_controller.text),
    );
  }
}

class _ViolationBadge extends StatelessWidget {
  const _ViolationBadge({
    required this.violations,
    required this.elements,
    required this.color,
    required this.onSelect,
  });

  final List<LayoutViolation> violations;
  final List<PlacedElement> elements;
  final Color color;
  final ValueChanged<String?>? onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        key: const Key('canvas-violations'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => _show(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_outlined, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                '${violations.length} 件の不足',
                style: TextStyle(fontSize: 11, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('${violations.length} 件の不足'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in violations)
                    ListTile(
                      key: Key('canvas-violation:${item.code}:${item.elementId}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.error_outline, color: color),
                      title: Text(describeViolation(item, elements)),
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        onSelect?.call(item.elementId);
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }
}
