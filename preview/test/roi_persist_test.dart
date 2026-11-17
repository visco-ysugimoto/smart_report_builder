import 'package:flutter_test/flutter_test.dart';
import 'package:smart_report_preview/roi_persist.dart';

void main() {
  test('reads the duplicated roi id and whether it moved', () {
    final moved = parseDuplicateResult('duplicated roi-2\nshift yes\n');
    expect(moved.roiId, 'roi-2');
    expect(moved.shifted, isTrue);

    final stacked = parseDuplicateResult('duplicated roi-4\nshift no\n');
    expect(stacked.roiId, 'roi-4');
    expect(stacked.shifted, isFalse);

    expect(
      () => parseDuplicateResult('updated roi-1\n'),
      throwsFormatException,
    );
  });

  test('reads how many folder images were registered', () {
    final registration = parseFolderRegistration('registered 2 skipped 1\n');
    expect(registration.added, 2);
    expect(registration.skipped, 1);
    expect(
      () => parseFolderRegistration('registered none\n'),
      throwsFormatException,
    );
  });

  test('reads layout proposals without applying them', () {
    final proposals = parseLayoutProposals(
      'standard\tselected\t標準\t今の配置\nequal\topen\t等分\t枠を等分する\n',
    );
    expect(proposals, hasLength(2));
    expect(proposals.first.selected, isTrue);
    expect(proposals.last.id, 'equal');
    expect(proposals.last.reason, '枠を等分する');
  });
}
