import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/roi_links.dart';

void main() {
  test('reads which roi is linked to a zoom frame', () {
    final links = parseRoiZoomLinks('''
      {
        "schemaVersion": 1,
        "slide": {
          "rois": [
            {"id": "roi-1", "zoomElementId": "frame-zoom"},
            {"id": "roi-2", "zoomElementId": null}
          ]
        }
      }
    ''');

    expect(links['roi-1'], 'frame-zoom');
    expect(links['roi-2'], isNull);
    expect(links.length, 2);
  });

  test('a slide without rois has no links', () {
    expect(parseRoiZoomLinks('{"schemaVersion": 1, "slide": {}}'), isEmpty);
  });

  test(
    'link needs a chosen zoom frame that is not already used by that roi',
    () {
      expect(
        canLinkSelection(
          knownRoi: true,
          currentZoomId: null,
          targetZoomId: 'frame-zoom',
        ),
        isTrue,
      );
      expect(
        canLinkSelection(
          knownRoi: true,
          currentZoomId: 'frame-zoom',
          targetZoomId: 'frame-zoom-b',
        ),
        isTrue,
      );
      expect(
        canLinkSelection(
          knownRoi: true,
          currentZoomId: 'frame-zoom',
          targetZoomId: 'frame-zoom',
        ),
        isFalse,
      );
      expect(
        canLinkSelection(
          knownRoi: true,
          currentZoomId: null,
          targetZoomId: null,
        ),
        isFalse,
      );
      expect(
        canLinkSelection(
          knownRoi: false,
          currentZoomId: null,
          targetZoomId: 'frame-zoom',
        ),
        isFalse,
      );
      expect(
        canUnlinkSelection(knownRoi: true, currentZoomId: 'frame-zoom'),
        isTrue,
      );
      expect(canUnlinkSelection(knownRoi: true, currentZoomId: null), isFalse);
      expect(
        canUnlinkSelection(knownRoi: false, currentZoomId: 'frame-zoom'),
        isFalse,
      );
    },
  );

  test('unassigned asset names omit assets already used by a frame', () {
    const source = '''
      {"schemaVersion": 1, "assets": [
        {"id": "asset-overall", "displayName": "全体画像"},
        {"id": "asset-extra", "displayName": "追加画像"}
      ], "slide": {"bindings": [
        {"elementId": "frame-overall", "assetId": "asset-overall"}
      ]}}
    ''';
    expect(parseUnassignedAssetNames(source), ['追加画像']);
    expect(parseUnassignedAssets(source).single.id, 'asset-extra');
  });

  test('an assigned asset can be shared onto another contain frame', () {
    const source = '''
      {"schemaVersion": 1, "assets": [
        {"id": "asset-overall", "displayName": "全体画像"},
        {"id": "asset-extra", "displayName": "追加画像"}
      ], "slide": {"bindings": [
        {"elementId": "frame-overall", "assetId": "asset-overall"},
        {"elementId": "frame-compare", "assetId": "asset-overall"}
      ]}}
    ''';
    final assigned = parseAssignedAssets(source);
    expect(assigned.single.id, 'asset-overall');
    expect(assigned.single.frameIds, ['frame-overall', 'frame-compare']);
    expect(
      canShareRegisteredAsset(
        frameId: 'frame-zoom',
        assetId: 'asset-overall',
        containFrame: true,
        frameIds: const ['frame-overall'],
      ),
      isTrue,
    );
    expect(
      canShareRegisteredAsset(
        frameId: 'frame-overall',
        assetId: 'asset-overall',
        containFrame: true,
        frameIds: const ['frame-overall'],
      ),
      isFalse,
    );
  });

  test('a shared asset lists every frame that uses it', () {
    const shared = AssignedAsset(
      id: 'asset-overall',
      name: '全体画像',
      frameIds: ['frame-overall', 'frame-compare'],
    );
    const single = AssignedAsset(
      id: 'asset-extra',
      name: '追加画像',
      frameIds: ['frame-zoom'],
    );
    const other = AssignedAsset(
      id: 'asset-2',
      name: '詳細画像',
      frameIds: ['frame-detail', 'missing-frame'],
    );
    expect(
      sharedAssetLines(
        assets: const [shared, single, other],
        frameNames: const {
          'frame-overall': '全体',
          'frame-compare': '比較',
          'frame-zoom': '拡大',
          'frame-detail': '詳細',
        },
      ),
      ['全体画像（全体、比較）', '詳細画像（詳細、missing-frame）'],
    );
    expect(
      sharedAssetLines(assets: const [single], frameNames: const {}),
      isEmpty,
    );
  });

  test('the selected asset reports the frames that use it', () {
    const shared = AssignedAsset(
      id: 'asset-overall',
      name: '全体画像',
      frameIds: ['frame-overall', 'frame-compare'],
    );
    expect(
      selectedAssetFrameIds(assetId: 'asset-overall', assets: const [shared]),
      {'frame-overall', 'frame-compare'},
    );
    expect(
      selectedAssetName(assetId: 'asset-overall', assets: const [shared]),
      '全体画像',
    );
    expect(
      selectedAssetName(assetId: null, assets: const [shared]),
      isNull,
    );
    expect(
      selectedAssetFrameIds(assetId: null, assets: const [shared]),
      isEmpty,
    );
    expect(
      selectedAssetFrameIds(assetId: 'missing', assets: const [shared]),
      isEmpty,
    );
  });

  test('a share target is shown only when that frame does not already use the asset', () {
    expect(
      shareDestinationFrameId(
        frameId: 'frame-compare',
        shareAssetChosen: true,
        assetFrameIds: const {'frame-overall'},
      ),
      'frame-compare',
    );
    expect(
      shareDestinationFrameId(
        frameId: 'frame-overall',
        shareAssetChosen: true,
        assetFrameIds: const {'frame-overall'},
      ),
      isNull,
    );
    expect(
      shareDestinationFrameId(
        frameId: 'frame-compare',
        shareAssetChosen: false,
        assetFrameIds: const {'frame-overall'},
      ),
      isNull,
    );
  });

  test('only an asset used by the share target alone is named before sharing', () {
    const overall = AssignedAsset(
      id: 'asset-overall',
      name: '全体画像',
      frameIds: ['frame-overall'],
    );
    const comparison = AssignedAsset(
      id: 'asset-compare',
      name: '  比較画像の全文  ',
      frameIds: ['frame-compare'],
    );
    const shared = AssignedAsset(
      id: 'asset-shared',
      name: '共有画像',
      frameIds: ['frame-compare', 'frame-detail'],
    );
    expect(
      assetLeftUnassignedByShare(
        frameId: 'frame-compare',
        shareAssetId: 'asset-overall',
        assets: const [overall, comparison],
      ),
      '  比較画像の全文  ',
    );
    expect(
      assetDisplacedByShare(
        frameId: 'frame-compare',
        shareAssetId: 'asset-overall',
        assets: const [overall, comparison],
      )?.id,
      'asset-compare',
    );
    expect(
      assetLeftUnassignedByShare(
        frameId: 'frame-compare',
        shareAssetId: 'asset-overall',
        assets: const [overall, shared],
      ),
      isNull,
    );
    expect(
      assetDisplacedByShare(
        frameId: 'frame-compare',
        shareAssetId: 'asset-overall',
        assets: const [overall, shared],
      ),
      isNull,
    );
    expect(
      assetLeftUnassignedByShare(
        frameId: null,
        shareAssetId: 'asset-overall',
        assets: const [comparison],
      ),
      isNull,
    );
  });

  test('an unused asset record can be removed when one is chosen', () {
    expect(
      canRemoveUnusedAsset(assetId: 'asset-extra', unassignedAsset: true),
      isTrue,
    );
    expect(
      canRemoveUnusedAsset(assetId: null, unassignedAsset: true),
      isFalse,
    );
    expect(
      canRemoveUnusedAsset(assetId: 'asset-overall', unassignedAsset: false),
      isFalse,
    );
  });

  test('a registered asset can be assigned when a contain frame is chosen', () {
    expect(
      canAssignRegisteredAsset(
        frameId: 'frame-compare',
        assetId: 'asset-extra',
        containFrame: true,
        unassignedAsset: true,
      ),
      isTrue,
    );
    expect(
      canAssignRegisteredAsset(
        frameId: null,
        assetId: 'asset-extra',
        containFrame: true,
        unassignedAsset: true,
      ),
      isFalse,
    );
    expect(
      canAssignRegisteredAsset(
        frameId: 'frame-compare',
        assetId: 'asset-extra',
        containFrame: true,
        unassignedAsset: false,
      ),
      isFalse,
    );
  });

  test('an image can be assigned only to a chosen contain frame', () {
    expect(
      canAssignImage(frameId: 'frame-overall', containFrame: true),
      isTrue,
    );
    expect(canAssignImage(frameId: null, containFrame: true), isFalse);
    expect(
      canAssignImage(frameId: 'frame-zoom', containFrame: false),
      isFalse,
    );
    expect(
      canUnassignImage(frameId: 'frame-compare', assigned: true),
      isTrue,
    );
    expect(
      canUnassignImage(frameId: 'frame-compare', assigned: false),
      isFalse,
    );
    expect(canUnassignImage(frameId: null, assigned: true), isFalse);
  });

  test('a shared frame offers to clear only that frame', () {
    const shared = AssignedAsset(
      id: 'asset-overall',
      name: '全体画像',
      frameIds: ['frame-overall', 'frame-compare'],
    );
    const single = AssignedAsset(
      id: 'asset-compare',
      name: '比較画像',
      frameIds: ['frame-detail'],
    );
    expect(
      frameSharesAsset(
        frameId: 'frame-compare',
        assets: const [shared, single],
      ),
      isTrue,
    );
    expect(
      frameSharesAsset(frameId: 'frame-detail', assets: const [shared, single]),
      isFalse,
    );
    expect(unassignActionLabel(sharedFrame: true), 'この枠の共有を外す');
    expect(unassignActionLabel(sharedFrame: false), '割当を外す');
  });

  test('a note can be saved when the trimmed text changed', () {
    const source = '''
      {"schemaVersion": 1, "slide": {"rois": [
        {"id": "roi-1", "note": "傷"},
        {"id": "roi-2"}
      ]}}
    ''';
    expect(parseRoiNotes(source), {'roi-1': '傷', 'roi-2': ''});
    expect(
      canSaveNote(knownRoi: true, currentNote: '傷', editedNote: '  傷の注釈  '),
      isTrue,
    );
    expect(
      canSaveNote(knownRoi: true, currentNote: '傷', editedNote: '傷'),
      isFalse,
    );
    expect(
      canSaveNote(knownRoi: true, currentNote: '傷', editedNote: '   '),
      isTrue,
    );
    expect(
      canSaveNote(knownRoi: false, currentNote: '', editedNote: '傷'),
      isFalse,
    );
  });

  test('a manual note position can be returned to automatic placement', () {
    const source = '''
      {"schemaVersion": 1, "slide": {"rois": [
        {"id": "roi-1", "note": "傷", "noteDx": 40, "noteDy": -10},
        {"id": "roi-2", "note": "傷", "noteDx": 12},
        {"id": "roi-3", "note": "傷"}
      ]}}
    ''';
    expect(parseManualNoteIds(source), {'roi-1'});
    expect(
      canResetNotePosition(
        knownRoi: true,
        currentNote: '傷',
        manualPosition: true,
      ),
      isTrue,
    );
    expect(
      canResetNotePosition(
        knownRoi: true,
        currentNote: '   ',
        manualPosition: true,
      ),
      isFalse,
    );
    expect(
      canResetNotePosition(
        knownRoi: true,
        currentNote: '傷',
        manualPosition: false,
      ),
      isFalse,
    );
    expect(
      canResetNotePosition(
        knownRoi: false,
        currentNote: '傷',
        manualPosition: true,
      ),
      isFalse,
    );
  });

  test('rename is available when the trimmed name is different', () {
    expect(
      canRenameRoi(knownRoi: true, currentName: 'ROI', editedName: '  傷A  '),
      isTrue,
    );
    expect(
      canRenameRoi(knownRoi: true, currentName: 'ROI', editedName: '  ROI  '),
      isFalse,
    );
    expect(
      canRenameRoi(knownRoi: true, currentName: 'ROI', editedName: '   '),
      isFalse,
    );
    expect(
      canRenameRoi(knownRoi: false, currentName: 'ROI', editedName: '傷A'),
      isFalse,
    );
  });

  test('an exact unused asset is a ready candidate and is not assigned', () {
    const source = '''
      {
        "schemaVersion": 1,
        "contentMaster": {
          "root": {
            "kind": "stack",
            "children": [
              {
                "id": "frame-overall",
                "kind": "image_frame",
                "roleId": "overall",
                "displayName": "全体画像",
                "fitMode": "contain"
              }
            ]
          }
        },
        "assets": [
          {"id": "asset-overall", "displayName": "全体画像", "path": "overall.png"}
        ],
        "slide": {"bindings": []}
      }
    ''';
    final candidates = parseAssignmentCandidates(source);
    expect(candidates, hasLength(1));
    expect(candidates.single.status, 'ready');
    expect(candidates.single.assetId, 'asset-overall');
    expect(candidates.single.reason, '表示名が一致');
  });

  test('a table cell saves only when its text changes', () {
    expect(
      canSaveTableCell(
        knownCell: true,
        currentText: '  値  ',
        editedText: '  値  ',
      ),
      isFalse,
    );
    expect(
      canSaveTableCell(
        knownCell: true,
        currentText: '値',
        editedText: '  測定値は短縮してはいけません。  ',
      ),
      isTrue,
    );
    expect(
      canSaveTableCell(knownCell: false, currentText: '', editedText: '値'),
      isFalse,
    );
  });

  test('a dataset groups assets only when a name and an asset exist', () {
    expect(canCreateDataset(name: '  対象A  ', assetCount: 2), isTrue);
    expect(canCreateDataset(name: '   ', assetCount: 2), isFalse);
    expect(canCreateDataset(name: '対象A', assetCount: 0), isFalse);
    final datasets = parseDatasets('''
      {
        "schemaVersion": 1,
        "datasets": [
          {"id": "dataset-1", "name": "  対象Aの全文  ", "assetIds": ["asset-1", "asset-1"]}
        ]
      }
    ''');
    expect(datasets.single.name, '  対象Aの全文  ');
    expect(datasets.single.assetIds, ['asset-1']);
    expect(parseDatasets('{"schemaVersion": 1}'), isEmpty);
  });
}
