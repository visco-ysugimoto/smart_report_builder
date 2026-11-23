import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/layout_result.dart';

void main() {
  const group = SlideRect(x: 40, y: 80, width: 400, height: 200);
  const picture = SlideRect(x: 90, y: 100, width: 100, height: 160);

  test('enlarging keeps the aspect and stays inside the image area', () {
    final next = scalePicture(picture, group, 1.15);
    expect(next.width / next.height, closeTo(picture.width / picture.height, 0.001));
    expect(next.x, greaterThanOrEqualTo(group.x));
    expect(next.y, greaterThanOrEqualTo(group.y));
    expect(next.x + next.width, lessThanOrEqualTo(group.x + group.width));
    expect(next.y + next.height, lessThanOrEqualTo(group.y + group.height));
    expect(next.width, greaterThan(picture.width));
  });

  test('shrinking keeps a visible picture', () {
    final next = scalePicture(picture, group, 0.2);
    expect(next.width, greaterThanOrEqualTo(group.width * 0.08 - 0.1));
    expect(next.width / next.height, closeTo(picture.width / picture.height, 0.001));
  });

  test('a fitted picture becomes a fraction of its row', () {
    final normalized = normalizePicture(picture, group);
    expect(normalized.x, closeTo(0.125, 0.001));
    expect(normalized.y, closeTo(0.1, 0.001));
    expect(normalized.width, closeTo(0.25, 0.001));
    expect(normalized.height, closeTo(0.8, 0.001));
  });

  test('a heading stays outside the saved frame', () {
    const element = PlacedElement(
      elementId: 'frame-2',
      kind: 'image_frame',
      roleId: 'zoom',
      displayName: '拡大画像',
      frame: SlideRect(x: 40, y: 104, width: 200, height: 156),
      contentRect: SlideRect(x: 70, y: 104, width: 120, height: 156),
      text: '見出し',
      assetPath: 'a.png',
      fitMode: 'roi',
      crop: null,
      textAnchor: 'above',
      labelFrame: SlideRect(x: 40, y: 80, width: 200, height: 24),
    );
    final slot = frameSlot(element);
    expect(slot.y, 80);
    expect(slot.height, 180);
    final around = slotAroundPicture(pictureBox(element), element);
    expect(around.y, 80);
    expect(around.height, 180);
    expect(around.width, pictureBox(element).width);
  });

  test('moving stops at the edge of the image area', () {
    final next = movePicture(picture, group, -200, 80);
    expect(next.x, group.x);
    expect(next.y + next.height, group.y + group.height);
    expect(next.width, picture.width);
  });
}
