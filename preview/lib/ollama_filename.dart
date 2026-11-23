import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:smart_report_preview/image_library.dart';

const ollamaEndpoint = 'http://127.0.0.1:11434';

class OllamaClassifyException implements Exception {
  OllamaClassifyException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _fastModels = [
  'qwen2.5:3b',
  'qwen2.5:1.5b',
  'qwen3:4b',
  'gemma3:4b',
  'gemma3:1b',
  'llama3.2:3b',
];

/// ファイル名の分類に使うモデル。小さい指示モデルを、大きい汎用モデルより優先する。
String? preferredOllamaModel(Iterable<String> names) {
  final list = [
    for (final name in names)
      if (name.trim().isNotEmpty) name.trim(),
  ];
  if (list.isEmpty) return null;
  final byLower = {for (final name in list) name.toLowerCase(): name};
  for (final wanted in _fastModels) {
    final found = byLower[wanted];
    if (found != null) return found;
  }
  for (final name in list) {
    final family = name.split(':').first.toLowerCase();
    if (family.startsWith('qwen') || family.startsWith('gemma3') || family.startsWith('llama3.2')) {
      return name;
    }
  }
  return list.first;
}

List<String> classificationLabels(LibrarySource source) {
  final labels = <String>[];
  final seen = <String>{};
  for (final group in source.groups) {
    if (isCatchAllGroup(group)) continue;
    final label = (commentToken(group) ?? group.label).trim();
    if (label.isEmpty || !seen.add(label.toLowerCase())) continue;
    labels.add(label);
  }
  return labels;
}

/// ファイル名に分類名そのものが含まれるとき、その分類を返す。長い名前を優先する。
String? ruleFilenameCategory(String name, List<String> categories) {
  final haystack = name.toLowerCase();
  final ranked = [
    for (final category in categories)
      if (category.trim().isNotEmpty && category.trim() != 'その他') category.trim(),
  ]..sort((a, b) => b.length.compareTo(a.length));
  for (final category in ranked) {
    if (haystack.contains(category.toLowerCase())) return category;
  }
  return null;
}

const _categoryCodes = 'ABCDEFGHJKLMNPQRSTUVWXYZ';

Map<String, String> categoryCodes(List<String> categories) {
  final codes = <String, String>{};
  for (final category in categories) {
    final label = category.trim();
    if (label.isEmpty || label == 'その他' || codes.containsValue(label)) continue;
    if (codes.length >= _categoryCodes.length) break;
    codes[_categoryCodes[codes.length]] = label;
  }
  return codes;
}

/// 「1:? 2:A」のような短い応答を、ファイル名から分類名へ直す。
///
/// ファイル名の先頭文字はコードにしない。判断できない番号は「その他」にする。
Map<String, String> parseFilenameCodes(
  String content, {
  required List<String> names,
  required Map<String, String> codes,
}) {
  final found = <int, String>{};
  final patterns = [
    RegExp(r'(\d+)\s*[:：=]\s*([A-Za-z?])'),
    RegExp(r'(\d+)\s*([A-Za-z?])(?=$|[\s,;])'),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(content)) {
      final index = int.parse(match.group(1)!);
      if (index < 1 || index > names.length || found.containsKey(index)) continue;
      final code = match.group(2)!.toUpperCase();
      if (code != '?' && !codes.containsKey(code)) continue;
      found[index] = code == '?' ? 'その他' : codes[code]!;
    }
  }
  return {
    for (var index = 0; index < names.length; index++)
      names[index]: found[index + 1] ?? 'その他',
  };
}

String filenameCodePrompt(List<String> names, Map<String, String> codes) {
  final legend = [
    for (final entry in codes.entries) '${entry.key}=${entry.value}',
    '?=その他',
  ].join(' ');
  final allowed = [...codes.keys, '?'].join(' ');
  final lines = [
    for (var index = 0; index < names.length; index++) '${index + 1} ${names[index]}',
  ].join('\n');
  return '''
番号ごとにコードを1つ書く。ファイル名は書かない。使えるコードは $allowed だけ。
$legend
形式: 1:? 2:A 3:B
$lines
''';
}

/// モデルの JSON を、入力したファイル名から分類名への対応に直す。
Map<String, String> parseFilenameClassification(
  String content, {
  required List<String> names,
  required List<String> categories,
}) {
  final known = <String, String>{};
  for (final category in categories) {
    final label = category.trim();
    if (label.isEmpty || label == 'その他') continue;
    known.putIfAbsent(label.toLowerCase(), () => label);
  }
  final exact = <String, String>{};
  for (final name in names) {
    exact.putIfAbsent(name.toLowerCase(), () => name);
  }
  final decoded = _decodeObject(content);
  if (decoded == null) throw OllamaClassifyException('分類結果を読み取れませんでした');
  final assigned = <String, String>{};
  final fresh = <String, String>{};
  final items = decoded['items'] ?? decoded['assignments'];
  if (items is List) {
    for (final item in items) {
      if (item is! Map) continue;
      final rawName = item['name']?.toString() ?? '';
      final name = exact[rawName.trim().toLowerCase()];
      if (name == null) continue;
      assigned[name] = _normalizeCategory(
        item['category']?.toString() ?? '',
        known: known,
        fresh: fresh,
      );
    }
    return assigned;
  }
  for (final entry in decoded.entries) {
    final index = int.tryParse(entry.key);
    final name = index != null && index >= 1 && index <= names.length
        ? names[index - 1]
        : exact[entry.key.trim().toLowerCase()];
    if (name == null) continue;
    assigned[name] = _normalizeCategory(entry.value?.toString() ?? '', known: known, fresh: fresh);
  }
  if (assigned.isEmpty) throw OllamaClassifyException('分類結果を読み取れませんでした');
  return assigned;
}

/// 先頭の記号で分ける指示なら、モデルを使わずファイル名から分類名を決める。
bool instructionUsesLeadingSymbol(String instruction) {
  final text = instruction.trim();
  if (text.isEmpty) return false;
  final lower = text.toLowerCase();
  if (text.contains('先頭') || text.contains('記号') || text.contains('プレフィックス')) return true;
  if (lower.contains('prefix')) return true;
  return RegExp(r'[A-Za-z0-9][_＿]').hasMatch(text);
}

/// `_` より前を分類名にする。`L-OK_リング深度_....bmp` は L-OK、`S.png` は S。
String leadingSymbolOf(String name) {
  final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
  if (stem.isEmpty) return 'その他';
  final head = stem.split(RegExp(r'[_＿]')).first.trim();
  return head.isEmpty ? 'その他' : head;
}

Map<String, String> classifyLeadingSymbols(Iterable<String> names) {
  return {for (final name in names) name: leadingSymbolOf(name)};
}

/// ユーザーの指示に沿った「1:分類名」を、ファイル名から分類名へ直す。
///
/// ファイル名そのものが返った番号は「その他」にする。1件も読めなければ失敗にする。
Map<String, String> parseInstructedClassification(
  String content, {
  required List<String> names,
  required List<String> categories,
  Map<String, String>? fresh,
}) {
  final known = <String, String>{};
  for (final category in categories) {
    final label = category.trim();
    if (label.isEmpty || label == 'その他') continue;
    known.putIfAbsent(label.toLowerCase(), () => label);
  }
  final created = fresh ?? <String, String>{};
  final found = <int, String>{};
  final patterns = [
    RegExp(r'(?:^|\n)\s*(\d+)\s*[:：.、)\]]\s*(\S+)'),
    RegExp(r'(?:^|\n)\s*(\d+)\s+(\S+)'),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(content)) {
      final index = int.parse(match.group(1)!);
      if (index < 1 || index > names.length || found.containsKey(index)) continue;
      final raw = _labelWithoutFileName(match.group(2)!.trim(), names[index - 1]);
      if (raw == null) continue;
      final label = _leadingSymbol(raw, names[index - 1]);
      found[index] = _normalizeCategory(label, known: known, fresh: created, maxFresh: 24);
    }
  }
  if (found.isEmpty) throw OllamaClassifyException('分類結果を読み取れませんでした');
  return {
    for (var index = 0; index < names.length; index++)
      names[index]: found[index + 1] ?? 'その他',
  };
}

String _leadingSymbol(String label, String name) {
  final head = label.split('_').first.trim();
  if (head.isEmpty || head == label) return label;
  final stem = name.replaceFirst(RegExp(r'\.[^.]+$'), '').toLowerCase();
  if (stem.startsWith(label.toLowerCase())) return head;
  return label;
}

String? _labelWithoutFileName(String label, String name) {
  var text = label.trim();
  if (text.isEmpty) return null;
  final lower = text.toLowerCase();
  final file = name.toLowerCase();
  if (lower == file) return null;
  if (lower.endsWith(file)) {
    text = text.substring(0, text.length - name.length).replaceAll(RegExp(r'[\s:：]+$'), '');
  }
  if (RegExp(r'\.(png|jpe?g|bmp|gif|webp|tiff?)$', caseSensitive: false).hasMatch(text)) {
    return null;
  }
  return text.trim().isEmpty ? null : text.trim();
}

String filenameInstructionPrompt(
  List<String> names,
  String instruction,
  List<String> categories,
) {
  final known = [
    for (final category in categories)
      if (category.trim().isNotEmpty && category.trim() != 'その他') category.trim(),
  ];
  final lines = [
    for (var index = 0; index < names.length; index++) '${index + 1} ${names[index]}',
  ].join('\n');
  return '''
指示に従ってファイル名を分類する。画像は見ない。
指示: $instruction
既存の分類: ${known.isEmpty ? 'なし' : known.join(', ')}
各行は「番号:分類名」だけにする。分類名は短くし、ファイル名の続きは付けない。
先頭の記号で分けるときは、最初の _ より前だけを書く。判断できなければ その他。
例:
1:B
2:L-OK
3:その他
$lines
''';
}

/// 利用中のチャットAIへ貼り付ける文。画像は含めず、ファイル名と指示だけを書く。
String externalClassifyPrompt(
  List<String> names,
  String instruction,
  List<String> categories,
) {
  final guidance = instruction.trim().isEmpty
      ? 'ファイル名のまとまりが分かる短い分類名にする'
      : instruction.trim();
  final known = [
    for (final category in categories)
      if (category.trim().isNotEmpty && category.trim() != 'その他') category.trim(),
  ];
  return '''
ファイル名だけを見て分類してください。画像は見ないでください。

指示: $guidance
既存の分類: ${known.isEmpty ? 'なし。必要なら短い分類名を新しく作る' : known.join(', ')}
分類名は16文字以内。既存の分類があればその名前を使う。判断できなければ その他。

回答は説明を書かず、1ファイルにつき次の1行だけにしてください。
ファイル名 => 分類名
ファイル名は下の一覧から1文字も変えずに写してください。

ファイル名:
${names.join('\n')}
''';
}

/// チャットAIの返答を、ファイル名から分類名へ直す。
///
/// 「ファイル名 => 分類名」を優先し、番号だけの返答も同じ並びなら読む。
/// 返答に無いファイルは結果に入れず、今の分類のままにする。
Map<String, String> parseExternalClassification(
  String content, {
  required List<String> names,
  required List<String> categories,
  String instruction = '',
}) {
  final known = <String, String>{};
  for (final category in categories) {
    final label = category.trim();
    if (label.isEmpty || label == 'その他') continue;
    known.putIfAbsent(label.toLowerCase(), () => label);
  }
  final fresh = <String, String>{};
  final shorten = instructionUsesLeadingSymbol(instruction);
  final assigned = <String, String>{};
  var text = content.replaceAll('`', '').replaceAll('*', '');
  final ordered = [...names]..sort((a, b) => b.length.compareTo(a.length));
  for (final name in ordered) {
    if (name.trim().isEmpty) continue;
    final match = RegExp(
      '${RegExp.escape(name)}\\s*(?:=>|⇒|->|→|＝|\\|\\s*|[:：])\\s*([^\\n|]+)',
    ).firstMatch(text);
    if (match == null) continue;
    text = text.replaceRange(match.start, match.end, ' ' * (match.end - match.start));
    final cleaned = _labelWithoutFileName(_shortReplyLabel(match.group(1)!), name);
    if (cleaned == null) continue;
    final label = shorten ? _leadingSymbol(cleaned, name) : cleaned;
    assigned[name] = _normalizeCategory(label, known: known, fresh: fresh, maxFresh: 24);
  }
  final numbered = _numberedReplyLabels(content, names);
  for (var index = 0; index < names.length; index++) {
    final name = names[index];
    if (assigned.containsKey(name)) continue;
    final raw = numbered[index + 1];
    if (raw == null) continue;
    final label = shorten ? _leadingSymbol(raw, name) : raw;
    assigned[name] = _normalizeCategory(label, known: known, fresh: fresh, maxFresh: 24);
  }
  if (assigned.isEmpty) {
    throw OllamaClassifyException(
      '分類結果を読み取れませんでした。各行が「ファイル名 => 分類名」になっているか確認してください。',
    );
  }
  return assigned;
}

Map<int, String> _numberedReplyLabels(String content, List<String> names) {
  final found = <int, String>{};
  final patterns = [
    RegExp(r'(?:^|\n)\s*(\d+)\s*[:：.、)\]]\s*(\S+)'),
    RegExp(r'(?:^|\n)\s*(\d+)\s+(\S+)'),
  ];
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(content)) {
      final index = int.parse(match.group(1)!);
      if (index < 1 || index > names.length || found.containsKey(index)) continue;
      final raw = _labelWithoutFileName(_shortReplyLabel(match.group(2)!), names[index - 1]);
      if (raw == null) continue;
      found[index] = raw;
    }
  }
  return found;
}

String _shortReplyLabel(String raw) {
  var text = raw.trim().replaceAll(RegExp(r'^["「『]+|["」』]+$'), '');
  text = text.split(RegExp(r'[（(。]')).first.trim();
  if (text.contains(' ')) {
    final first = text.split(RegExp(r'\s+')).first.trim();
    if (first.isNotEmpty && first.runes.length <= 16) return first;
  }
  return text;
}

String filenameClassifyPrompt(List<String> names, List<String> categories) {
  final known = [
    for (final category in categories)
      if (category.trim().isNotEmpty && category.trim() != 'その他') category.trim(),
  ];
  final lines = [
    for (var index = 0; index < names.length; index++) '${index + 1} ${names[index]}',
  ].join('\n');
  return '''
番号を分類する。画像は見ない。分類: ${known.isEmpty ? 'なし' : known.join(', ')}
$lines
JSONのみ。キーは番号、値は分類名。既存の分類を優先する。無ければファイル名の短い語。不明は その他。
例 {"1":"傷"}
''';
}

class OllamaFilenameClassifier {
  OllamaFilenameClassifier({this.endpoint = ollamaEndpoint, this._client});

  final String endpoint;
  final HttpClient? _client;

  Future<Map<String, String>> classify({
    required List<String> names,
    required List<String> categories,
    String instruction = '',
    void Function(int completedChunks, int totalChunks)? onProgress,
  }) async {
    final unique = <String>[];
    final seen = <String>{};
    for (final name in names) {
      final trimmed = name.trim();
      if (trimmed.isEmpty || !seen.add(trimmed.toLowerCase())) continue;
      unique.add(trimmed);
    }
    if (unique.isEmpty) return const {};
    final guidance = instruction.trim();
    if (instructionUsesLeadingSymbol(guidance)) {
      onProgress?.call(1, 1);
      return classifyLeadingSymbols(unique);
    }
    final codes = categoryCodes(categories);
    final assigned = <String, String>{};
    final pending = <String>[];
    if (guidance.isEmpty) {
      for (final name in unique) {
        final local = ruleFilenameCategory(name, categories);
        if (local == null) {
          pending.add(name);
        } else {
          assigned[name] = local;
        }
      }
    } else {
      pending.addAll(unique);
    }
    final fresh = <String, String>{};
    if (pending.isEmpty) {
      onProgress?.call(1, 1);
      return assigned;
    }
    final client = _client ?? HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final model = await _modelName(client);
      final size = guidance.isEmpty ? 16 : 12;
      final chunks = (pending.length + size - 1) ~/ size;
      for (var index = 0; index < chunks; index++) {
        final start = index * size;
        final end = start + size > pending.length ? pending.length : start + size;
        final part = await _classifyChunk(
          client,
          model: model,
          names: pending.sublist(start, end),
          categories: categories,
          codes: codes,
          instruction: guidance,
          fresh: fresh,
        );
        assigned.addAll(part);
        onProgress?.call(index + 1, chunks);
      }
      return assigned;
    } on OllamaClassifyException {
      rethrow;
    } on SocketException {
      throw OllamaClassifyException('Ollama が起動していません');
    } on TimeoutException {
      throw OllamaClassifyException('分類が時間内に終わりませんでした');
    } on HttpException {
      throw OllamaClassifyException('Ollama と通信できません');
    } finally {
      if (_client == null) client.close(force: true);
    }
  }

  Future<String> _modelName(HttpClient client) async {
    final body = await _get(client, '/api/tags');
    final decoded = jsonDecode(body);
    final models = decoded is Map ? decoded['models'] : null;
    final names = <String>[];
    if (models is List) {
      for (final model in models) {
        if (model is Map && model['name'] is String) names.add(model['name'] as String);
      }
    }
    final picked = preferredOllamaModel(names);
    if (picked == null) throw OllamaClassifyException('Ollama にモデルがありません');
    return picked;
  }

  Future<Map<String, String>> _classifyChunk(
    HttpClient client, {
    required String model,
    required List<String> names,
    required List<String> categories,
    required Map<String, String> codes,
    String instruction = '',
    Map<String, String>? fresh,
  }) async {
    final guided = instruction.trim().isNotEmpty;
    final coded = !guided && codes.isNotEmpty;
    final payload = <String, Object?>{
      'model': model,
      'stream': false,
      'think': false,
      'keep_alive': '10m',
      'options': {
        'temperature': 0,
        'num_ctx': coded ? 2048 : 4096,
        'num_predict': guided
            ? names.length * 24 + 40
            : coded
            ? names.length * 8 + 24
            : names.length * 12 + 32,
      },
      'messages': [
        {
          'role': 'user',
          'content': guided
              ? filenameInstructionPrompt(names, instruction.trim(), categories)
              : coded
              ? filenameCodePrompt(names, codes)
              : filenameClassifyPrompt(names, categories),
        },
      ],
    };
    if (!guided && !coded) payload['format'] = 'json';
    final body = await _post(client, '/api/chat', payload);
    final decoded = jsonDecode(body);
    final content = decoded is Map ? decoded['message'] : null;
    final text = content is Map ? content['content']?.toString() ?? '' : '';
    if (text.trim().isEmpty) {
      throw OllamaClassifyException('分類結果を読み取れませんでした');
    }
    if (guided) {
      return parseInstructedClassification(
        text,
        names: names,
        categories: categories,
        fresh: fresh,
      );
    }
    if (coded) return parseFilenameCodes(text, names: names, codes: codes);
    return parseFilenameClassification(text, names: names, categories: categories);
  }

  Future<String> _get(HttpClient client, String path) {
    return _send(client, (http) => http.getUrl(_uri(path)));
  }

  Future<String> _post(HttpClient client, String path, Map<String, Object?> payload) {
    return _send(client, (http) async {
      final request = await http.postUrl(_uri(path));
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.add(utf8.encode(jsonEncode(payload)));
      return request;
    });
  }

  Future<String> _send(
    HttpClient client,
    Future<HttpClientRequest> Function(HttpClient client) open,
  ) async {
    final request = await open(client);
    final response = await request.close().timeout(const Duration(seconds: 90));
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OllamaClassifyException('Ollama の応答が不正です');
    }
    return text;
  }

  Uri _uri(String path) => Uri.parse('$endpoint$path');
}

const _labelNoise = {
  'img',
  'image',
  'images',
  'dsc',
  'pic',
  'pics',
  'photo',
  'photos',
  'copy',
  'scan',
  'camera',
  'file',
  'files',
};

Map<String, Object?>? _decodeObject(String content) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) return null;
  final direct = _tryDecode(trimmed);
  if (direct != null) return direct;
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  return _tryDecode(trimmed.substring(start, end + 1));
}

Map<String, Object?>? _tryDecode(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.map((key, value) => MapEntry(key.toString(), value));
  } on FormatException {
    return null;
  }
  return null;
}

String _normalizeCategory(
  String raw, {
  required Map<String, String> known,
  required Map<String, String> fresh,
  int maxFresh = 12,
}) {
  final label = raw.trim();
  if (label.isEmpty || label == 'その他' || label.toLowerCase() == 'other') return 'その他';
  final existing = known[label.toLowerCase()];
  if (existing != null) return existing;
  if (!_acceptableNewLabel(label)) return 'その他';
  final key = label.toLowerCase();
  if (fresh.length >= maxFresh && !fresh.containsKey(key)) return 'その他';
  return fresh.putIfAbsent(key, () => label);
}

bool _acceptableNewLabel(String label) {
  final length = label.runes.length;
  if (length < 1 || length > 16) return false;
  if (label.contains('.') || label.contains('/') || label.contains('\\')) return false;
  if (RegExp(r'''[:*?"<>|]''').hasMatch(label)) return false;
  return !_labelNoise.contains(label.toLowerCase());
}
