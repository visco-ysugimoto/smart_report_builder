import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:smart_report_preview/state/app_scope.dart';

class SlideSummary {
  SlideSummary({required this.id, required this.name, required this.title});

  final String id;
  final String name;
  final String title;
}

/// 左側のサムネイルタイムライン。スライド順と選択を扱う。
class ThumbnailStrip extends StatelessWidget {
  const ThumbnailStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.stateOf(context);
    final slides = _parseSlides(state.projectJson);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.view_carousel_outlined, size: 18),
                const SizedBox(width: 6),
                Text(
                  'スライド',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                Text(
                  '${slides.length} 枚',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: slides.isEmpty
                  ? Center(
                      child: Text(
                        'まだ展開していません',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.separated(
                      key: const Key('timeline-list'),
                      itemCount: slides.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final slide = slides[index];
                        final selected = slide.id == state.selectedSlideId ||
                            (state.selectedSlideId == null && index == 0);
                        return _SlideTile(
                          index: index + 1,
                          slide: slide,
                          selected: selected,
                          onTap: () {
                            state.selectSlide(slide.id);
                            if (slides.length > 1) {
                              AppScope.serviceOf(context).activateSlide(slide.id);
                            }
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<SlideSummary> _parseSlides(String? json) {
    if (json == null) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return const [];
      final slides = decoded['slides'];
      if (slides is List && slides.isNotEmpty) {
        return [
          for (final raw in slides)
            if (raw is Map)
              SlideSummary(
                id: '${raw['id']}',
                name: '${raw['name']}',
                title: '${(raw['slide'] as Map?)?['title'] ?? ''}',
              ),
        ];
      }
      final single = decoded['slide'];
      if (single is Map) {
        return [
          SlideSummary(
            id: '${single['id']}',
            name: 'スライド1',
            title: '${single['title'] ?? ''}',
          ),
        ];
      }
    } on FormatException {
      return const [];
    }
    return const [];
  }
}

class _SlideTile extends StatelessWidget {
  const _SlideTile({
    required this.index,
    required this.slide,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final SlideSummary slide;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('timeline-tile:${slide.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: selected ? Colors.white : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      slide.title.isEmpty ? slide.name : slide.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      slide.id,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
