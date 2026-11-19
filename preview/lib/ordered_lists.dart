import 'dart:convert';

class OrderedAsset {
  const OrderedAsset({
    required this.id,
    required this.name,
    required this.group,
    required this.task,
    required this.listName,
    required this.listComment,
    required this.listIndex,
    this.note = '',
    this.fileName = '',
  });

  final String id;
  final String name;
  final String group;
  final String task;
  final String listName;
  final String listComment;
  final int listIndex;
  final String note;
  final String fileName;
}

class CatalogList {
  const CatalogList({
    required this.group,
    required this.task,
    required this.listName,
    required this.listComment,
    required this.position,
    required this.taskPosition,
  });

  final String group;
  final String task;
  final String listName;
  final String listComment;
  final int position;
  final int taskPosition;

  String get label {
    if (listComment.isNotEmpty) {
      return listComment;
    }
    if (listName.isNotEmpty) {
      return listName;
    }
    return '$taskPosition番目のリスト';
  }
}

class ListOption {
  const ListOption({required this.value, required this.label});

  final String value;
  final String label;
}

class ResolvedPick {
  const ResolvedPick({required this.status, required this.name, required this.reason});

  final String status;
  final String name;
  final String reason;
}

List<OrderedAsset> parseOrderedAssets(String? projectJson) {
  if (projectJson == null || projectJson.isEmpty) {
    return const [];
  }
  final decoded = jsonDecode(projectJson);
  if (decoded is! Map) {
    return const [];
  }
  final assets = decoded['assets'];
  if (assets is! List) {
    return const [];
  }
  final found = <OrderedAsset>[];
  for (final item in assets) {
    if (item is! Map || item['listIndex'] is! num) {
      continue;
    }
    found.add(
      OrderedAsset(
        id: '${item['id']}',
        name: '${item['displayName'] ?? ''}',
        group: '${item['group'] ?? ''}',
        task: '${item['task'] ?? ''}',
        listName: '${item['listName'] ?? ''}',
        listComment: '${item['listComment'] ?? ''}',
        listIndex: (item['listIndex'] as num).toInt(),
        note: '${item['note'] ?? ''}',
        fileName: '${item['fileName'] ?? ''}',
      ),
    );
  }
  return found;
}

List<CatalogList> catalogLists(List<OrderedAsset> assets) {
  final keys = <String>{};
  final ordered = <List<String>>[];
  for (final asset in assets) {
    final key = [asset.group, asset.task, asset.listName, asset.listComment];
    final token = key.join('\u0000');
    if (keys.add(token)) {
      ordered.add(key);
    }
  }
  ordered.sort((a, b) {
    for (var index = 0; index < a.length; index++) {
      final compared = a[index].compareTo(b[index]);
      if (compared != 0) {
        return compared;
      }
    }
    return 0;
  });
  final taskCounts = <String, int>{};
  final lists = <CatalogList>[];
  for (final key in ordered) {
    final taskKey = '${key[0]}\u0000${key[1]}';
    taskCounts[taskKey] = (taskCounts[taskKey] ?? 0) + 1;
    lists.add(
      CatalogList(
        group: key[0],
        task: key[1],
        listName: key[2],
        listComment: key[3],
        position: lists.length + 1,
        taskPosition: taskCounts[taskKey]!,
      ),
    );
  }
  return lists;
}

List<ListOption> listOptions(List<CatalogList> lists) {
  final commentCounts = <String, int>{};
  for (final list in lists) {
    if (list.listComment.isNotEmpty) {
      commentCounts[list.listComment] = (commentCounts[list.listComment] ?? 0) + 1;
    }
  }
  final options = <ListOption>[];
  for (final list in lists) {
    if (list.listComment.isNotEmpty && commentCounts[list.listComment] == 1) {
      options.add(ListOption(value: 'comment:${list.listComment}', label: list.label));
    } else if (list.listName.isNotEmpty) {
      options.add(ListOption(value: 'name:${list.listName}', label: list.label));
    }
  }
  final positions = lists.map((list) => list.taskPosition).toSet().toList()..sort();
  for (final position in positions) {
    options.add(ListOption(value: 'position:$position', label: '$position番目のリスト'));
  }
  return options;
}

ResolvedPick resolvePick(
  List<OrderedAsset> assets,
  String listBy,
  String listKey,
  int itemNumber,
) {
  final lists = _matching(catalogLists(assets), listBy, listKey);
  if (lists.isEmpty) {
    return ResolvedPick(status: 'missing', name: '', reason: '$listKey の$itemNumber番がありません');
  }
  if (lists.length > 1) {
    return ResolvedPick(status: 'conflict', name: '', reason: '同じ指定のリストが複数あります: $listKey');
  }
  final list = lists.single;
  final found = [
    for (final asset in assets)
      if (asset.listIndex == itemNumber &&
          asset.group == list.group &&
          asset.task == list.task &&
          asset.listName == list.listName &&
          asset.listComment == list.listComment)
        asset,
  ];
  if (found.isEmpty) {
    return ResolvedPick(status: 'missing', name: '', reason: '${list.label} に$itemNumber番がありません');
  }
  if (found.length > 1) {
    return ResolvedPick(status: 'conflict', name: '', reason: '${list.label} の$itemNumber番が複数あります');
  }
  return ResolvedPick(status: 'ready', name: found.single.name, reason: '${list.label} の$itemNumber番');
}

List<CatalogList> _matching(List<CatalogList> lists, String listBy, String listKey) {
  if (listBy == 'position') {
    return [for (final list in lists) if ('${list.taskPosition}' == listKey) list];
  }
  if (listBy == 'name') {
    return [for (final list in lists) if (list.listName == listKey) list];
  }
  final byComment = [
    for (final list in lists)
      if (list.listComment.isNotEmpty && list.listComment == listKey) list,
  ];
  if (byComment.isNotEmpty) {
    return byComment;
  }
  return [
    for (final list in lists)
      if (list.listComment.isEmpty && list.listName == listKey) list,
  ];
}

const labelVariableHelp = <(String, String)>[
  ('{comment}', '一覧の Comment='),
  ('{note}', 'その画像のコメント'),
  ('{txt}', 'txt のファイル名'),
  ('{file}', 'FILE= のファイル名'),
  ('{n}', 'FILE= の番号'),
  ('{index}', 'FILE= の番号'),
  ('{slide}', 'スライド番号'),
  ('{group}', 'グループ'),
  ('{task}', 'タスク'),
];

class RenderedLabel {
  const RenderedLabel(this.text, this.missing);

  final String text;
  final List<String> missing;
}

RenderedLabel renderLabel(
  String template, {
  String comment = '',
  String note = '',
  String txt = '',
  String file = '',
  String index = '',
  String slide = '',
  String group = '',
  String task = '',
  Map<String, String> extra = const {},
}) {
  final values = <String, String>{
    'comment': comment,
    'note': note,
    'txt': txt,
    'file': file,
    'index': index,
    'n': index,
    'slide': slide,
    'group': group,
    'task': task,
    ...extra,
  };
  final missing = <String>[];
  final text = template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (match) {
    final key = match.group(1) ?? '';
    final value = values[key] ?? '';
    if (value.isEmpty) {
      missing.add(key);
      return '';
    }
    return value;
  });
  return RenderedLabel(text, missing);
}
