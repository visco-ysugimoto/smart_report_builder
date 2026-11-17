import 'dart:convert';

bool supportedProjectSchema(Object? version) {
  return version is num && (version == 1 || version == 2);
}

/// プロジェクト JSON から、ROI とその拡大枠 ID だけを読む。配置は計算しない。
Map<String, String?> parseRoiZoomLinks(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  final version = decoded['schemaVersion'];
  if (!supportedProjectSchema(version)) {
    throw FormatException('unsupported schemaVersion: $version');
  }
  final slide = decoded['slide'];
  if (slide is! Map) {
    throw const FormatException('slide がない');
  }
  final rois = slide['rois'];
  if (rois == null) {
    return {};
  }
  if (rois is! List) {
    throw const FormatException('rois が配列ではない');
  }
  final links = <String, String?>{};
  for (final item in rois) {
    if (item is! Map) {
      throw const FormatException('ROI がオブジェクトではない');
    }
    final id = item['id'];
    final zoomId = item['zoomElementId'];
    if (id is! String) {
      throw const FormatException('ROI の id がない');
    }
    if (zoomId != null && zoomId is! String) {
      throw const FormatException('zoomElementId が文字列ではない');
    }
    links[id] = zoomId;
  }
  return links;
}

bool canLinkSelection({
  required bool knownRoi,
  required String? currentZoomId,
  required String? targetZoomId,
}) {
  return knownRoi && targetZoomId != null && currentZoomId != targetZoomId;
}

/// プロジェクト JSON から、ROI の注釈だけを読む。無い注釈は空文字。
Map<String, String> parseRoiNotes(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  final version = decoded['schemaVersion'];
  if (!supportedProjectSchema(version)) {
    throw FormatException('unsupported schemaVersion: $version');
  }
  final slide = decoded['slide'];
  if (slide is! Map) {
    throw const FormatException('slide がない');
  }
  final rois = slide['rois'];
  if (rois == null) {
    return {};
  }
  if (rois is! List) {
    throw const FormatException('rois が配列ではない');
  }
  final notes = <String, String>{};
  for (final item in rois) {
    if (item is! Map) {
      throw const FormatException('ROI がオブジェクトではない');
    }
    final id = item['id'];
    final note = item['note'];
    if (id is! String) {
      throw const FormatException('ROI の id がない');
    }
    if (note != null && note is! String) {
      throw const FormatException('note が文字列ではない');
    }
    notes[id] = note ?? '';
  }
  return notes;
}

/// 両方のずれが保存されている ROI だけを返す。片方だけでは自動配置のまま。
Set<String> parseManualNoteIds(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  final version = decoded['schemaVersion'];
  if (!supportedProjectSchema(version)) {
    throw FormatException('unsupported schemaVersion: $version');
  }
  final slide = decoded['slide'];
  if (slide is! Map) {
    throw const FormatException('slide がない');
  }
  final rois = slide['rois'];
  if (rois == null) {
    return {};
  }
  if (rois is! List) {
    throw const FormatException('rois が配列ではない');
  }
  final placed = <String>{};
  for (final item in rois) {
    if (item is! Map) {
      throw const FormatException('ROI がオブジェクトではない');
    }
    final id = item['id'];
    if (id is! String) {
      throw const FormatException('ROI の id がない');
    }
    if (item['noteDx'] is num && item['noteDy'] is num) {
      placed.add(id);
    }
  }
  return placed;
}

bool canResetNotePosition({
  required bool knownRoi,
  required String currentNote,
  required bool manualPosition,
}) {
  return knownRoi && currentNote.trim().isNotEmpty && manualPosition;
}

class RegisteredAsset {
  const RegisteredAsset({required this.id, required this.name});

  final String id;
  final String name;
}

/// どの枠にも割り当てられていない素材。登録順を保つ。
List<RegisteredAsset> parseUnassignedAssets(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  final version = decoded['schemaVersion'];
  if (!supportedProjectSchema(version)) {
    throw FormatException('unsupported schemaVersion: $version');
  }
  final assets = decoded['assets'];
  if (assets is! List) {
    throw const FormatException('assets が配列ではない');
  }
  final slide = decoded['slide'];
  if (slide is! Map) {
    throw const FormatException('slide がない');
  }
  final bindings = slide['bindings'];
  final used = <String>{};
  if (bindings is List) {
    for (final item in bindings) {
      if (item is! Map) {
        continue;
      }
      final assetId = item['assetId'];
      if (assetId is String) {
        used.add(assetId);
      }
    }
  }
  final unassigned = <RegisteredAsset>[];
  for (final item in assets) {
    if (item is! Map) {
      throw const FormatException('素材がオブジェクトではない');
    }
    final id = item['id'];
    final name = item['displayName'];
    if (id is! String || name is! String) {
      throw const FormatException('素材の id または表示名がない');
    }
    if (!used.contains(id)) {
      unassigned.add(RegisteredAsset(id: id, name: name));
    }
  }
  return unassigned;
}

class AssignedAsset {
  const AssignedAsset({
    required this.id,
    required this.name,
    required this.frameIds,
  });

  final String id;
  final String name;
  final List<String> frameIds;
}

/// どの枠かに割り当てられている素材。登録順を保ち、枠は割当の順。
List<AssignedAsset> parseAssignedAssets(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  final version = decoded['schemaVersion'];
  if (!supportedProjectSchema(version)) {
    throw FormatException('unsupported schemaVersion: $version');
  }
  final assets = decoded['assets'];
  if (assets is! List) {
    throw const FormatException('assets が配列ではない');
  }
  final slide = decoded['slide'];
  if (slide is! Map) {
    throw const FormatException('slide がない');
  }
  final framesByAsset = <String, List<String>>{};
  final bindings = slide['bindings'];
  if (bindings is List) {
    for (final item in bindings) {
      if (item is! Map) {
        continue;
      }
      final assetId = item['assetId'];
      final elementId = item['elementId'];
      if (assetId is String && elementId is String) {
        framesByAsset.putIfAbsent(assetId, () => []).add(elementId);
      }
    }
  }
  final assigned = <AssignedAsset>[];
  for (final item in assets) {
    if (item is! Map) {
      throw const FormatException('素材がオブジェクトではない');
    }
    final id = item['id'];
    final name = item['displayName'];
    if (id is! String || name is! String) {
      throw const FormatException('素材の id または表示名がない');
    }
    final frameIds = framesByAsset[id];
    if (frameIds != null && frameIds.isNotEmpty) {
      assigned.add(AssignedAsset(id: id, name: name, frameIds: frameIds));
    }
  }
  return assigned;
}

/// 二つ以上の枠で使われている素材の表示。素材の順と、枠は割当の順。
/// 枠の表示名が無いときは枠 ID をそのまま出す。一つの枠だけの素材は含めない。
List<String> sharedAssetLines({
  required List<AssignedAsset> assets,
  required Map<String, String> frameNames,
}) {
  return [
    for (final asset in assets)
      if (asset.frameIds.length >= 2)
        '${asset.name}（${asset.frameIds.map((id) => frameNames[id] ?? id).join('、')}）',
  ];
}

/// どの枠にも割り当てられていない素材の表示名。登録順を保つ。
List<String> parseUnassignedAssetNames(String source) {
  return [
    for (final asset in parseUnassignedAssets(source)) asset.name,
  ];
}

bool canShareRegisteredAsset({
  required String? frameId,
  required String? assetId,
  required bool containFrame,
  required List<String> frameIds,
}) {
  if (frameId == null || assetId == null || !containFrame) {
    return false;
  }
  return frameIds.any((id) => id != frameId) && !frameIds.contains(frameId);
}

/// 選択中の素材を使っている枠 ID。未選択や未知の素材は空。
Set<String> selectedAssetFrameIds({
  required String? assetId,
  required List<AssignedAsset> assets,
}) {
  if (assetId == null) {
    return const {};
  }
  for (final asset in assets) {
    if (asset.id == assetId) {
      return asset.frameIds.toSet();
    }
  }
  return const {};
}

/// 選択中の素材の表示名。未選択や未知の素材は null。
String? selectedAssetName({
  required String? assetId,
  required List<AssignedAsset> assets,
}) {
  if (assetId == null) {
    return null;
  }
  for (final asset in assets) {
    if (asset.id == assetId) {
      return asset.name;
    }
  }
  return null;
}

/// 共有先として示す枠。素材が選ばれ、その枠がまだその素材を使っていないときだけ返す。
String? shareDestinationFrameId({
  required String? frameId,
  required bool shareAssetChosen,
  required Set<String> assetFrameIds,
}) {
  if (!shareAssetChosen || frameId == null) {
    return null;
  }
  if (assetFrameIds.contains(frameId)) {
    return null;
  }
  return frameId;
}

/// 共有先の枠だけが使っている素材名。共有すると未割当になるものだけを返す。
/// 共有先の枠だけが使っていて、共有後に未割当になる素材。
AssignedAsset? assetDisplacedByShare({
  required String? frameId,
  required String? shareAssetId,
  required List<AssignedAsset> assets,
}) {
  if (frameId == null || shareAssetId == null) {
    return null;
  }
  for (final asset in assets) {
    if (asset.id == shareAssetId) {
      continue;
    }
    if (asset.frameIds.length == 1 && asset.frameIds.single == frameId) {
      return asset;
    }
  }
  return null;
}

String? assetLeftUnassignedByShare({
  required String? frameId,
  required String? shareAssetId,
  required List<AssignedAsset> assets,
}) {
  return assetDisplacedByShare(
    frameId: frameId,
    shareAssetId: shareAssetId,
    assets: assets,
  )?.name;
}

bool canRemoveUnusedAsset({
  required String? assetId,
  required bool unassignedAsset,
}) {
  return assetId != null && unassignedAsset;
}

bool canAssignRegisteredAsset({
  required String? frameId,
  required String? assetId,
  required bool containFrame,
  required bool unassignedAsset,
}) {
  return frameId != null && assetId != null && containFrame && unassignedAsset;
}

bool canAssignImage({required String? frameId, required bool containFrame}) {
  return frameId != null && containFrame;
}

bool canUnassignImage({required String? frameId, required bool assigned}) {
  return frameId != null && assigned;
}

/// 選んだ枠の素材を、別の枠も使っている。
bool frameSharesAsset({
  required String? frameId,
  required List<AssignedAsset> assets,
}) {
  if (frameId == null) {
    return false;
  }
  return assets.any(
    (asset) => asset.frameIds.length >= 2 && asset.frameIds.contains(frameId),
  );
}

/// 共有中の枠は、その枠だけ外すことを示す。
String unassignActionLabel({required bool sharedFrame}) {
  return sharedFrame ? 'この枠の共有を外す' : '割当を外す';
}

bool canSaveNote({
  required bool knownRoi,
  required String currentNote,
  required String editedNote,
}) {
  return knownRoi && editedNote.trim() != currentNote;
}

bool canRenameRoi({
  required bool knownRoi,
  required String currentName,
  required String editedName,
}) {
  final next = editedName.trim();
  return knownRoi && next.isNotEmpty && next != currentName;
}

bool canSaveTableCell({
  required bool knownCell,
  required String currentText,
  required String editedText,
}) {
  return knownCell && editedText != currentText;
}

bool canUnlinkSelection({
  required bool knownRoi,
  required String? currentZoomId,
}) {
  return knownRoi && currentZoomId != null;
}

class AssignmentCandidate {
  const AssignmentCandidate({
    required this.status,
    required this.frameId,
    required this.assetId,
    required this.assetName,
    required this.reason,
    this.confidence = 1,
    this.label = '',
  });

  final String status;
  final String frameId;
  final String assetId;
  final String assetName;
  final String reason;
  final double confidence;
  final String label;

  String get key => '$frameId|$assetId';

  String get mark => label.isEmpty ? status : label;

  bool get canAcceptAll => status == 'ready';
}

/// Python の `suggest` が返す1行を候補にする。割当はしない。
List<AssignmentCandidate> parseSuggestedAssignments(String stdout) {
  final found = <AssignmentCandidate>[];
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final parts = line.split('\t');
    if (parts.length < 7) {
      continue;
    }
    if (parts[0] != 'ready' && parts[0] != 'confirm' && parts[0] != 'conflict') {
      continue;
    }
    final confidence = double.tryParse(parts[4]);
    if (confidence == null) {
      continue;
    }
    found.add(
      AssignmentCandidate(
        status: parts[0],
        frameId: parts[1],
        assetId: parts[2],
        assetName: parts[3],
        confidence: confidence,
        label: parts[5],
        reason: parts.sublist(6).join('\t'),
      ),
    );
  }
  return found;
}

String assignmentCandidateLabel(AssignmentCandidate candidate, {String? frameName}) {
  final percent = (candidate.confidence * 100).round();
  final target = frameName == null || frameName.isEmpty ? candidate.frameId : frameName;
  return '${candidate.mark} $percent%: ${candidate.assetName} → $target（${candidate.reason}）';
}

/// 空の通常表示の枠と、未使用の素材の候補。割り当てはしない。
List<AssignmentCandidate> parseAssignmentCandidates(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('JSON オブジェクトではない');
  }
  final assets = decoded['assets'];
  final slide = decoded['slide'];
  final root = decoded['contentMaster'];
  if (assets is! List || slide is! Map || root is! Map) {
    return const [];
  }
  final tree = root['root'];
  if (tree is! Map) {
    return const [];
  }
  final used = <String>{};
  final bound = <String, String>{};
  final bindings = slide['bindings'];
  if (bindings is List) {
    for (final item in bindings) {
      if (item is! Map) {
        continue;
      }
      final assetId = item['assetId'];
      final elementId = item['elementId'];
      if (assetId is String && elementId is String) {
        used.add(assetId);
        bound[elementId] = assetId;
      }
    }
  }
  final unused = <Map<dynamic, dynamic>>[];
  for (final item in assets) {
    if (item is Map && item['id'] is String && !used.contains(item['id'])) {
      unused.add(item);
    }
  }
  final found = <AssignmentCandidate>[];
  for (final frame in _containFrames(tree)) {
    if (bound.containsKey(frame['id'])) {
      continue;
    }
    final exact = [
      for (final asset in unused)
        if (_exactName(frame, asset)) asset,
    ];
    if (exact.length == 1) {
      found.add(_candidate('ready', frame, exact.single, '表示名が一致'));
      continue;
    }
    if (exact.length > 1) {
      for (final asset in exact) {
        found.add(_candidate('confirm', frame, asset, '一致する素材が複数ある'));
      }
      continue;
    }
    for (final asset in unused) {
      if (_partialName(frame, asset)) {
        found.add(_candidate('confirm', frame, asset, '名前の一部だけ一致'));
      }
    }
  }
  return found;
}

List<String> parseMasterRoiIds(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    return const [];
  }
  final master = decoded['contentMaster'];
  if (master is! Map) {
    return const [];
  }
  final rois = master['masterRois'];
  if (rois is! List) {
    return const [];
  }
  return [
    for (final item in rois)
      if (item is Map && item['id'] is String) item['id'] as String,
  ];
}

AssignmentCandidate _candidate(
  String status,
  Map<dynamic, dynamic> frame,
  Map<dynamic, dynamic> asset,
  String reason,
) {
  return AssignmentCandidate(
    status: status,
    frameId: frame['id'] as String,
    assetId: asset['id'] as String,
    assetName: asset['displayName'] as String,
    reason: reason,
    confidence: status == 'ready' ? 1 : 0.5,
    label: status == 'conflict'
        ? '競合'
        : status == 'ready'
        ? '確定候補'
        : '確認推奨',
  );
}

bool _exactName(Map<dynamic, dynamic> frame, Map<dynamic, dynamic> asset) {
  final names = {
    '${frame['displayName']}'.toLowerCase(),
    '${frame['roleId']}'.toLowerCase(),
  };
  return names.contains('${asset['displayName']}'.toLowerCase()) ||
      names.contains(_stem('${asset['path']}').toLowerCase());
}

bool _partialName(Map<dynamic, dynamic> frame, Map<dynamic, dynamic> asset) {
  final haystack =
      '${asset['displayName']} ${_stem('${asset['path']}')}'.toLowerCase();
  for (final token in ['${frame['displayName']}', '${frame['roleId']}']) {
    final folded = token.toLowerCase().trim();
    if (folded.length >= 2 && haystack.contains(folded)) {
      return true;
    }
  }
  return false;
}

String _stem(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) {
    return name;
  }
  return name.substring(0, dot);
}

List<Map<dynamic, dynamic>> _containFrames(Map<dynamic, dynamic> node) {
  final kind = node['kind'];
  if (kind == 'image_frame' && node['fitMode'] == 'contain' && node['id'] is String) {
    return [node];
  }
  final children = node['children'];
  if (children is! List) {
    return const [];
  }
  final found = <Map<dynamic, dynamic>>[];
  for (final child in children) {
    if (child is Map) {
      found.addAll(_containFrames(child));
    }
  }
  return found;
}

class AssetDataset {
  const AssetDataset({
    required this.id,
    required this.name,
    required this.assetIds,
  });

  final String id;
  final String name;
  final List<String> assetIds;

  bool contains(String assetId) => assetIds.contains(assetId);
}

List<AssetDataset> parseDatasets(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    return const [];
  }
  final raw = decoded['datasets'];
  if (raw is! List) {
    return const [];
  }
  final datasets = <AssetDataset>[];
  for (final item in raw) {
    if (item is! Map || item['id'] is! String || item['name'] is! String) {
      continue;
    }
    final ids = <String>[];
    final assets = item['assetIds'];
    if (assets is List) {
      for (final assetId in assets) {
        if (assetId is String && !ids.contains(assetId)) {
          ids.add(assetId);
        }
      }
    }
    datasets.add(
      AssetDataset(
        id: item['id'] as String,
        name: item['name'] as String,
        assetIds: ids,
      ),
    );
  }
  return datasets;
}

bool canCreateDataset({required String name, required int assetCount}) {
  return name.trim().isNotEmpty && assetCount > 0;
}
