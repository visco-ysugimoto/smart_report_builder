import 'package:flutter/material.dart';

/// 候補の最大スライド番号と、いまある枚数から、足りない枚数を返す。
///
/// サーバの slidesToAdd が 0 でも、候補が既存の枚数を超えていればこちらを使う。
int missingSlides({
  required int reported,
  required int existingSlides,
  required Iterable<int> candidateOrdinals,
}) {
  final have = existingSlides < 1 ? 1 : existingSlides;
  var maxOrdinal = -1;
  for (final ordinal in candidateOrdinals) {
    if (ordinal > maxOrdinal) {
      maxOrdinal = ordinal;
    }
  }
  final fromCandidates = maxOrdinal + 1 > have ? maxOrdinal + 1 - have : 0;
  return reported > fromCandidates ? reported : fromCandidates;
}

class OrderedExpandBar extends StatelessWidget {
  const OrderedExpandBar({
    super.key,
    required this.slidesToAdd,
    required this.canExpand,
    required this.canAccept,
    required this.saving,
    required this.onExpand,
    required this.onAcceptAdding,
    required this.onAcceptExisting,
  });

  final int slidesToAdd;
  final bool canExpand;
  final bool canAccept;
  final bool saving;
  final VoidCallback onExpand;
  final VoidCallback onAcceptAdding;
  final VoidCallback onAcceptExisting;

  @override
  Widget build(BuildContext context) {
    final short = canAccept && slidesToAdd > 0;
    return Column(
      key: const Key('ordered-expand-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('ordered-expand'),
            onPressed: saving || !canExpand ? null : onExpand,
            child: const Text('スライドへ広げる'),
          ),
        ),
        if (short) ...[
          const SizedBox(height: 8),
          Text(
            'スライドが$slidesToAdd枚足りません',
            key: const Key('ordered-slides-short'),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('ordered-accept-new'),
                onPressed: saving ? null : onAcceptAdding,
                child: const Text('追加して採用'),
              ),
              TextButton(
                key: const Key('ordered-accept-existing'),
                onPressed: saving ? null : onAcceptExisting,
                child: const Text('既存分だけ採用'),
              ),
            ],
          ),
        ] else if (canAccept)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('ordered-accept-all'),
              onPressed: saving ? null : onAcceptAdding,
              child: const Text('すべて採用'),
            ),
          ),
      ],
    );
  }
}
