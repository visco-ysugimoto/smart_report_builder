import 'dart:io';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/theme/app_theme.dart';
import 'package:smart_report_preview/widgets/slide_canvas.dart';
import 'package:smart_report_preview/widgets/slide_inspector.dart';
import 'package:smart_report_preview/widgets/thumbnail_strip.dart';

/// Step 3: 展開後のスライドをタイムラインで確認し、個別に微調整する画面。
class ExpandScreen extends StatelessWidget {
  const ExpandScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TopBar(
          slideCount: state.slideCount,
          busy: state.busy,
          onAddText: () => service.addFreeText(slideId: state.selectedSlideId),
          onBack: () => service.returnToMaster(),
          onReExpand: () => service.expandUsingLibrary(),
          onExport: () async {
            final path = await _pickSavePath(context, state.projectDirectory);
            if (path == null) return;
            await service.exportPptx(path);
          },
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppDims.gutter),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(
                  width: AppDims.timelineWidth,
                  child: ThumbnailStrip(),
                ),
                const SizedBox(width: AppDims.gutter),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SlideCanvas(
                        key: const Key('expand-canvas'),
                        result: state.result,
                        selectedFrameId: state.selectedFrameId,
                        onSelectFrame: state.selectFrame,
                        onDropLibraryImage: (frameId, image) async {
                          await service.assignLibraryImage(
                            frameId: frameId,
                            image: image,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onRoleChange: (frameId, role) async {
                          await service.pickRole(frameId: frameId, role: role);
                        },
                        onZoomSource: (zoomFrameId, sourceFrameId) async {
                          await service.linkZoomSource(
                            zoomFrameId: zoomFrameId,
                            sourceFrameId: sourceFrameId,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onMoveZoomRegion: (zoomFrameId, x, y, width, height) async {
                          await service.moveZoomRegion(
                            zoomFrameId: zoomFrameId,
                            x: x,
                            y: y,
                            width: width,
                            height: height,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onHeading: (frameId, text) async {
                          await service.setHeading(
                            frameId: frameId,
                            text: text,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onHeadingPlace: (frameId, place) async {
                          await service.setHeadingPlace(
                            frameId: frameId,
                            place: place,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onHeadingSize: (frameId, size) async {
                          await service.setHeadingSize(
                            frameId: frameId,
                            size: size,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onTextSize: (textId, size) async {
                          await service.setTextSize(
                            textId: textId,
                            size: size,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onMoveText: (textId, x, y, width, height) async {
                          await service.moveFreeText(
                            textId: textId,
                            x: x,
                            y: y,
                            width: width,
                            height: height,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onTextBody: (textId, text) async {
                          await service.setFreeText(
                            textId: textId,
                            text: text,
                            slideId: state.selectedSlideId,
                          );
                        },
                        onDeleteText: (textId) async {
                          await service.deleteFreeText(
                            textId: textId,
                            slideId: state.selectedSlideId,
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppDims.gutter),
                const SizedBox(
                  width: AppDims.rightPaneWidth,
                  child: SlideInspector(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<String?> _pickSavePath(BuildContext context, String? directory) async {
    final controller = TextEditingController(
      text: directory == null
          ? 'report.pptx'
          : '$directory${Platform.pathSeparator}report_export.pptx',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('PPTX を書き出す'),
          content: TextField(
            key: const Key('export-path'),
            controller: controller,
            decoration: const InputDecoration(labelText: '保存先パス'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              key: const Key('export-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('書き出す'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.slideCount,
    required this.busy,
    required this.onAddText,
    required this.onBack,
    required this.onReExpand,
    required this.onExport,
  });

  final int slideCount;
  final bool busy;
  final VoidCallback onAddText;
  final VoidCallback onBack;
  final Future<void> Function() onReExpand;
  final Future<void> Function() onExport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          OutlinedButton.icon(
            key: const Key('expand-add-text'),
            onPressed: busy ? null : () => onAddText(),
            icon: const Icon(Icons.text_fields, size: 16),
            label: const Text('テキストを追加'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('expand-back'),
            onPressed: busy ? null : onBack,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('1枚目を編集'),
          ),
          const SizedBox(width: 16),
          Text(
            '$slideCount 枚のスライド',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            key: const Key('expand-reexpand'),
            onPressed: busy ? null : () => onReExpand(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('再展開'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('expand-export'),
            onPressed: busy ? null : () => onExport(),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('PPTX として保存'),
          ),
        ],
      ),
    );
  }
}
