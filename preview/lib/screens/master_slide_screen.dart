import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_scope.dart';
import 'package:smart_report_preview/theme/app_theme.dart';
import 'package:smart_report_preview/widgets/finding_editor.dart';
import 'package:smart_report_preview/widgets/layout_preset_bar.dart';
import 'package:smart_report_preview/widgets/slide_canvas.dart';
import 'package:smart_report_preview/widgets/source_tray.dart';

/// Step 2: 1 枚目を型として編集する画面。
///
/// 左: 画像トレイ、中央: プリセットバー + キャンバス、右: テンプレ入力、下部: 展開ボタン。
class MasterSlideScreen extends StatelessWidget {
  const MasterSlideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final service = AppScope.serviceOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.statusMessage != null || state.errorMessage != null)
          _NoticeBar(
            status: state.statusMessage,
            error: state.errorMessage,
            busy: state.busy,
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppDims.gutter),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: AppDims.sidebarWidth,
                  child: SourceTray(
                    key: const Key('master-source-tray'),
                    scope: 'master',
                  ),
                ),
                const SizedBox(width: AppDims.gutter),
                Expanded(
                  child: Column(
                    children: [
                      const LayoutPresetBar(),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: SlideCanvas(
                              key: const Key('master-canvas'),
                              result: state.result,
                              selectedFrameId: state.selectedFrameId,
                              onSelectFrame: state.selectFrame,
                              onDropLibraryImage: (frameId, image) async {
                                await service.assignLibraryImage(
                                  frameId: frameId,
                                  image: image,
                                );
                              },
                              onRoleChange: (frameId, role) async {
                                await service.pickRole(frameId: frameId, role: role);
                              },
                              onZoomSource: (zoomFrameId, sourceFrameId) async {
                                await service.linkZoomSource(
                                  zoomFrameId: zoomFrameId,
                                  sourceFrameId: sourceFrameId,
                                );
                              },
                              onMoveZoomRegion: (zoomFrameId, x, y, width, height) async {
                                await service.moveZoomRegion(
                                  zoomFrameId: zoomFrameId,
                                  x: x,
                                  y: y,
                                  width: width,
                                  height: height,
                                );
                              },
                              onHeading: (frameId, text) async {
                                await service.setHeading(frameId: frameId, text: text);
                              },
                              onHeadingPlace: (frameId, place) async {
                                await service.setHeadingPlace(frameId: frameId, place: place);
                              },
                              onHeadingSize: (frameId, size) async {
                                await service.setHeadingSize(frameId: frameId, size: size);
                              },
                              onTextSize: (textId, size) async {
                                await service.setTextSize(textId: textId, size: size);
                              },
                              onCaptionHeight: (textId, height) async {
                                await service.setCaptionHeight(height);
                              },
                              onMoveText: (textId, x, y, width, height) async {
                                await service.moveFreeText(
                                  textId: textId,
                                  x: x,
                                  y: y,
                                  width: width,
                                  height: height,
                                );
                              },
                              onTextBody: (textId, text) async {
                                await service.setFreeText(textId: textId, text: text);
                              },
                              onDeleteText: (textId) async {
                                await service.deleteFreeText(textId: textId);
                              },
                              onResizeFrame: (frameId, x, y, width, height) async {
                                await service.resizeFrame(
                                  frameId: frameId,
                                  x: x,
                                  y: y,
                                  width: width,
                                  height: height,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppDims.gutter),
                SizedBox(
                  width: AppDims.rightPaneWidth,
                  child: Column(
                    children: [
                      const Expanded(child: FindingEditor()),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        key: const Key('master-add-text'),
                        onPressed: state.busy ? null : () => service.addFreeText(),
                        icon: const Icon(Icons.text_fields, size: 16),
                        label: const Text('テキストを追加'),
                      ),
                      const SizedBox(height: 8),
                      _ExpandButton(
                        enabled: !state.busy &&
                            state.hasOpenProject &&
                            state.totalLibraryImages >= 1,
                        onPressed: () => service.expandUsingLibrary(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ExpandButton extends StatelessWidget {
  const _ExpandButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('expand-button'),
        onPressed: enabled ? () => onPressed() : null,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        icon: const Icon(Icons.auto_awesome_motion, size: 20),
        label: const Text('この型でスライドを展開'),
      ),
    );
  }
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.status, required this.error, required this.busy});

  final String? status;
  final String? error;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isError = error != null;
    final message = isError ? error! : (status ?? '');
    if (message.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: isError
          ? scheme.errorContainer.withValues(alpha: 0.4)
          : scheme.primaryContainer.withValues(alpha: 0.5),
      child: Row(
        children: [
          if (busy)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              size: 16,
              color: isError ? scheme.error : scheme.primary,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              key: Key(isError ? 'notice-error' : 'notice-status'),
              style: TextStyle(
                color: isError ? scheme.onErrorContainer : scheme.onPrimaryContainer,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
