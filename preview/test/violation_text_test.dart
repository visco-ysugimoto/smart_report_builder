import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_result.dart';

void main() {
  const image = PlacedElement(
    elementId: 'frame-1',
    kind: 'image_frame',
    roleId: 'image',
    displayName: '画像',
    frame: SlideRect(x: 0, y: 0, width: 100, height: 100),
    contentRect: null,
    text: null,
    assetPath: null,
    fitMode: 'contain',
    crop: null,
  );
  const caption = PlacedElement(
    elementId: 'text-caption',
    kind: 'text',
    roleId: 'caption',
    displayName: '説明',
    frame: SlideRect(x: 0, y: 100, width: 100, height: 40),
    contentRect: null,
    text: '長い文章',
    assetPath: null,
    fitMode: 'contain',
    crop: null,
  );

  test('an unassigned image is named in the message', () {
    const violation = LayoutViolation(
      code: 'unassigned_image',
      elementId: 'frame-1',
      message: '画像枠に素材が割り当てられていない',
    );
    expect(
      describeViolation(violation, const [image, caption]),
      '画像 に画像が割り当てられていません',
    );
  });

  test('clipped finding text tells the user to widen the frame', () {
    const violation = LayoutViolation(
      code: 'text_overflow',
      elementId: 'text-caption',
      message: '文章が枠に入りきらない',
    );
    expect(
      describeViolation(violation, const [image, caption]),
      contains('説明 の文章が枠に入りきりません'),
    );
  });

  test('an overlap uses both frame names', () {
    const other = PlacedElement(
      elementId: 'frame-2',
      kind: 'image_frame',
      roleId: 'image',
      displayName: '拡大画像',
      frame: SlideRect(x: 0, y: 0, width: 100, height: 100),
      contentRect: null,
      text: null,
      assetPath: null,
      fitMode: 'roi',
      crop: null,
    );
    const violation = LayoutViolation(
      code: 'overlap',
      elementId: 'frame-2',
      message: 'frame-1 と重なっている',
    );
    expect(
      describeViolation(violation, const [image, other]),
      '拡大画像 が 画像 と重なっています',
    );
  });
}
