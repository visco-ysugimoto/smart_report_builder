import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/ollama_filename.dart';

void main() {
  test('prefers a small instruction model over a large one', () {
    expect(
      preferredOllamaModel(['gemma4:12b', 'llama3:8b', 'qwen2.5:3b']),
      'qwen2.5:3b',
    );
    expect(preferredOllamaModel(['gemma4:12b']), 'gemma4:12b');
    expect(preferredOllamaModel(const []), isNull);
  });

  test('keeps known category spelling and drops labels that are not names', () {
    final assigned = parseFilenameClassification(
      '{"items":['
      '{"name":"sample_傷.png","category":"傷"},'
      '{"name":"stain_left.jpg","category":"汚れ"},'
      '{"name":"overview.png","category":"other"},'
      '{"name":"missing.png","category":"傷"},'
      '{"name":"notes.png","category":"this-label-is-far-too-long"}'
      ']}',
      names: ['sample_傷.png', 'stain_left.jpg', 'overview.png', 'notes.png'],
      categories: ['傷', '汚れ'],
    );
    expect(assigned['sample_傷.png'], '傷');
    expect(assigned['stain_left.jpg'], '汚れ');
    expect(assigned['overview.png'], 'その他');
    expect(assigned.containsKey('missing.png'), isFalse);
    expect(assigned['notes.png'], 'その他');
  });

  test('a category written in the file name skips the model', () {
    expect(ruleFilenameCategory('汚れ_01.jpg', ['傷', '汚れ']), '汚れ');
    expect(ruleFilenameCategory('stain_left.jpg', ['傷', '汚れ']), isNull);
    expect(ruleFilenameCategory('傷大_01.png', ['傷', '傷大']), '傷大');
  });

  test('reads one-line category codes', () {
    final assigned = parseFilenameCodes(
      '1:A 2:B 3:? 4:C',
      names: ['sample_傷.png', 'stain_left.jpg', 'overview.png', 'edge_欠け.png'],
      codes: {'A': '傷', 'B': '汚れ', 'C': '欠け'},
    );
    expect(assigned['sample_傷.png'], '傷');
    expect(assigned['stain_left.jpg'], '汚れ');
    expect(assigned['overview.png'], 'その他');
    expect(assigned['edge_欠け.png'], '欠け');
  });

  test('a copied file name is not treated as a category code', () {
    final assigned = parseFilenameCodes(
      '1?\n2S.png\n3T.bmp',
      names: ['S.png', 'T.bmp', 'T.png'],
      codes: {'A': 'リング全焦点', 'B': 'リング深度'},
    );
    expect(assigned['S.png'], 'その他');
    expect(assigned['T.bmp'], 'その他');
    expect(assigned['T.png'], 'その他');
  });

  test('leading symbols stay with their own files', () async {
    final assigned = await OllamaFilenameClassifier().classify(
      names: [
        'L.png',
        'N_リング全焦点_C02R014.bmp',
        'O_リング深度_C02R015.bmp',
        'L-OK_リング全焦点_C02R014.bmp',
        'S.png',
      ],
      categories: ['リング全焦点', 'リング深度'],
      instruction: '先頭の記号ごとに分類してください(B_,S_など)',
    );
    expect(assigned['L.png'], 'L');
    expect(assigned['N_リング全焦点_C02R014.bmp'], 'N');
    expect(assigned['O_リング深度_C02R015.bmp'], 'O');
    expect(assigned['L-OK_リング全焦点_C02R014.bmp'], 'L-OK');
    expect(assigned['S.png'], 'S');
  });

  test('a space separated reply keeps the symbol before the underscore', () {
    final assigned = parseInstructedClassification(
      '1 B\n2 B_リング全焦点\n3 L-OK_リング深度\n4 その他',
      names: [
        'B.png',
        'B_リング全焦点_C02R014.bmp',
        'L-OK_リング深度_C02R015.bmp',
        'notes.png',
      ],
      categories: ['リング全焦点', 'リング深度'],
    );
    expect(assigned['B.png'], 'B');
    expect(assigned['B_リング全焦点_C02R014.bmp'], 'B');
    expect(assigned['L-OK_リング深度_C02R015.bmp'], 'L-OK');
    expect(assigned['notes.png'], 'その他');
  });

  test('an instruction can create a new category and ignore copied file names', () {
    final assigned = parseInstructedClassification(
      '1:B\n2:S.png\n3:その他\n4:L-OK',
      names: [
        'B_リング全焦点_C02R014.bmp',
        'S.png',
        'overview.png',
        'L-OK_リング深度_C02R015.bmp',
      ],
      categories: ['リング全焦点', 'リング深度'],
    );
    expect(assigned['B_リング全焦点_C02R014.bmp'], 'B');
    expect(assigned['S.png'], 'その他');
    expect(assigned['overview.png'], 'その他');
    expect(assigned['L-OK_リング深度_C02R015.bmp'], 'L-OK');
  });

  test('reads numbered categories without repeating file names', () {
    final assigned = parseFilenameClassification(
      '{"1":"傷","2":"汚れ","3":"other"}',
      names: ['sample_傷.png', 'stain_left.jpg', 'overview.png'],
      categories: ['傷', '汚れ'],
    );
    expect(assigned['sample_傷.png'], '傷');
    expect(assigned['stain_left.jpg'], '汚れ');
    expect(assigned['overview.png'], 'その他');
  });

  test('a cloud prompt lists file names and asks not to look at images', () {
    final prompt = externalClassifyPrompt(
      ['N_リング全焦点_C02R014.bmp', 'O.png'],
      '先頭の記号ごとに分ける',
      ['リング全焦点'],
    );
    expect(prompt, contains('画像は見ないでください'));
    expect(prompt, contains('先頭の記号ごとに分ける'));
    expect(prompt, contains('N_リング全焦点_C02R014.bmp'));
    expect(prompt, contains('O.png'));
    expect(prompt, contains('ファイル名 => 分類名'));
  });

  test('a cloud reply keeps each file with the label after the arrow', () {
    final assigned = parseExternalClassification(
      '分類しました。\n'
      'N_リング全焦点_C02R014.bmp => N\n'
      '| O_リング深度_C02R015.bmp | O |\n'
      'L-OK_リング全焦点_C02R014.bmp => L-OK（先頭）\n',
      names: [
        'L.png',
        'N_リング全焦点_C02R014.bmp',
        'O_リング深度_C02R015.bmp',
        'L-OK_リング全焦点_C02R014.bmp',
      ],
      categories: ['リング全焦点'],
      instruction: '先頭の記号ごとに分ける',
    );
    expect(assigned['N_リング全焦点_C02R014.bmp'], 'N');
    expect(assigned['O_リング深度_C02R015.bmp'], 'O');
    expect(assigned['L-OK_リング全焦点_C02R014.bmp'], 'L-OK');
    expect(assigned.containsKey('L.png'), isFalse);
  });

  test('a numbered cloud reply follows the file list order', () {
    final assigned = parseExternalClassification(
      '1:N\n2:O',
      names: ['N_a.bmp', 'O_b.bmp', 'S.png'],
      categories: const [],
    );
    expect(assigned['N_a.bmp'], 'N');
    expect(assigned['O_b.bmp'], 'O');
    expect(assigned.containsKey('S.png'), isFalse);
  });

  test('reads a new short label from a wrapped reply', () {
    final assigned = parseFilenameClassification(
      '分類しました\n{"items":[{"name":"edge_欠け.png","category":"欠け"}]}',
      names: ['edge_欠け.png'],
      categories: ['傷'],
    );
    expect(assigned['edge_欠け.png'], '欠け');
  });
}
