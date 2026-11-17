import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/roi_persist.dart';

void main() {
  test('a project without pages stays a single layout', () {
    final pages = parseReportPages('{"schemaVersion": 1, "slide": {}}');
    expect(pages.pages, isEmpty);
    expect(pages.layouts, isEmpty);
    expect(pages.activeId, isNull);
  });

  test('one layout is still listed from the content master name', () {
    final pages = parseReportPages('''
      {"contentMaster": {"name": "画像2枚と説明"}}
    ''');
    expect(pages.pages.single.id, 'slide-1');
    expect(pages.pages.single.name, 'スライド1');
    expect(pages.layouts.single.name, '画像2枚と説明');
    expect(pages.activeId, 'slide-1');
  });

  test('slides choose a shared layout', () {
    final pages = parseReportPages('''
      {
        "layouts": [
          {"id": "layout-1", "name": "画像2枚と説明"},
          {"id": "layout-2", "name": "全体画像と拡大"}
        ],
        "slides": [
          {"id": "slide-1", "name": "スライド1", "layoutId": "layout-1"},
          {"id": "slide-2", "name": "Slide_Image2", "layoutId": "layout-2"},
          {"id": "slide-3", "name": "Slide_Image3", "layoutId": "layout-2"}
        ],
        "activeSlideId": "slide-2"
      }
    ''');
    expect(pages.pages.map((page) => page.layoutId), [
      'layout-1',
      'layout-2',
      'layout-2',
    ]);
    expect(pages.activeId, 'slide-2');
  });

  test('pages name the layouts stored in one project', () {
    final pages = parseReportPages('''
      {
        "pages": [
          {"id": "page-1", "name": "画像2枚と説明"},
          {"id": "page-2", "name": "全体画像と拡大"}
        ],
        "activePageId": "page-2"
      }
    ''');
    expect(pages.pages.map((page) => page.name), [
      '画像2枚と説明',
      '全体画像と拡大',
    ]);
    expect(pages.activeId, 'page-2');
  });
}
