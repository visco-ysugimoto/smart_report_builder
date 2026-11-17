import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/ordered_lists.dart';

void main() {
  test('resolves two lists by comment and falls back to the txt name', () {
    const assets = [
      OrderedAsset(
        id: 'a1',
        name: 'cam1.bmp',
        group: 'g01',
        task: '03',
        listName: 'outer',
        listComment: '外観',
        listIndex: 1,
      ),
      OrderedAsset(
        id: 'b1',
        name: 'proc1.bmp',
        group: 'g01',
        task: '03',
        listName: 'inner',
        listComment: '',
        listIndex: 1,
      ),
    ];

    expect(resolvePick(assets, 'comment', '外観', 1).name, 'cam1.bmp');
    expect(resolvePick(assets, 'name', 'inner', 1).name, 'proc1.bmp');
    expect(resolvePick(assets, 'position', '2', 1).name, 'proc1.bmp');
    expect(resolvePick(assets, 'comment', '外観', 4).status, 'missing');
  });

  test('a repeated comment is a conflict', () {
    const assets = [
      OrderedAsset(
        id: 'a',
        name: 'a.bmp',
        group: 'g01',
        task: '03',
        listName: 'one',
        listComment: '外観',
        listIndex: 1,
      ),
      OrderedAsset(
        id: 'b',
        name: 'b.bmp',
        group: 'g01',
        task: '03',
        listName: 'two',
        listComment: '外観',
        listIndex: 1,
      ),
    ];

    expect(resolvePick(assets, 'comment', '外観', 1).status, 'conflict');
  });
}