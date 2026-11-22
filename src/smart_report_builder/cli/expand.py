"""登録した画像を 1 枚目の型に沿って N 枚のスライドへ展開する。

画像はプロジェクトへの登録順（トレイの並び）で取り、通常表示の枠の数ごとに
次のスライドへ進む。VTV の txt リストには分けない。
"""

from __future__ import annotations

import argparse
import sys

from smart_report_builder import roi_edit
from smart_report_builder.models import Binding, FitMode, ImageFrameNode, TextNode
from smart_report_builder.ordered_assignment import render_label


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="expand-slides",
        description="Expand the master into N slides using registered assets",
    )
    parser.add_argument("project")
    parser.add_argument("--range-to", type=int, default=0, help="終了スライド (0 で自動)")
    parser.add_argument("--overwrite-labels", action="store_true")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = roi_edit.load_project(args.project)
        applied = _expand_in_tray_order(
            project,
            range_to=args.range_to or None,
            overwrite_labels=args.overwrite_labels,
        )
        roi_edit._save_outputs(project, args.project, args.layout, args.pptx, record_undo=True)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    slides = len(project.report_slides) or 1
    print(f"expanded slides {slides} applied {applied}")
    return 0


def _expand_in_tray_order(project, *, range_to: int | None, overwrite_labels: bool) -> int:
    """取り込み順の画像を、通常表示の枠の数ごとにスライドへ割り当てる。

    VTV のタスクは txt ごとに別リストになる。リストの「1番目」だけを見ると、
    配置した画像が競合扱いになって1枚も載らない。
    """
    frames = _contain_frames(project.content_master.root)
    if not frames:
        raise ValueError("通常表示の画像枠がありません")
    assets = list(project.assets)
    if not assets:
        raise ValueError("展開する画像がありません")
    order = {asset.id: index for index, asset in enumerate(assets)}
    preserved, last_used = _preserved_first_slide(project.slide, frames, order)
    tail = assets[last_used + 1 :]
    per_slide = len(frames)
    empty_on_first = sum(1 for frame in frames if frame.id not in preserved)
    rest = max(0, len(tail) - empty_on_first)
    needed = 1 if rest == 0 else 1 + (rest + per_slide - 1) // per_slide
    if not preserved and not tail:
        raise ValueError("展開する画像がありません")
    if range_to is not None:
        needed = max(1, min(needed, range_to))
    if not project.report_slides:
        roi_edit._ensure_deck(project)
    layout = next(
        (item for item in project.layouts if item.id == project.report_slides[0].layout_id),
        None,
    )
    if layout is None:
        raise ValueError("レイアウトが見つからない")
    while len(project.report_slides) < needed:
        roi_edit._append_slide(project, layout)
    if len(project.report_slides) > needed:
        del project.report_slides[needed:]
    frame_ids = {frame.id for frame in frames}
    caption_id = _caption_id(project.content_master.root)
    rule = project.content_master.assignment_rule
    master_headings = _heading_snapshot(project.report_slides[0].slide, frame_ids)
    saved_headings = {
        report.id: _heading_snapshot(report.slide, frame_ids) for report in project.report_slides
    }
    applied = 0
    cursor = 0
    for ordinal, report_slide in enumerate(project.report_slides):
        slide = report_slide.slide
        prior = saved_headings.get(report_slide.id, {})
        slide.bindings = [item for item in slide.bindings if item.element_id not in frame_ids]
        chunk = []
        for frame in frames:
            if ordinal == 0 and frame.id in preserved:
                asset_id = preserved[frame.id]
                slide.bindings.append(
                    _binding_with_heading(frame.id, asset_id, prior.get(frame.id), master_headings.get(frame.id))
                )
                chunk.append(next(asset for asset in assets if asset.id == asset_id))
                applied += 1
                continue
            if cursor >= len(tail):
                break
            asset = tail[cursor]
            cursor += 1
            slide.bindings.append(
                _binding_with_heading(frame.id, asset.id, prior.get(frame.id), master_headings.get(frame.id))
            )
            chunk.append(asset)
            applied += 1
        if rule is not None and chunk:
            _apply_templates(
                slide,
                rule,
                chunk,
                ordinal + 1,
                caption_id,
                overwrite_labels=overwrite_labels,
            )
    _copy_zoom_regions(project)
    first = project.report_slides[0]
    project.active_slide_id = first.id
    project.slide = first.slide
    project.content_master = layout.content_master
    return applied


def _copy_zoom_regions(project) -> None:
    """1枚目で決めた拡大範囲を、同じ枠を使う後続スライドへコピーする。"""
    import copy

    slides = project.report_slides
    if len(slides) < 2:
        return
    template = slides[0].slide.rois
    for index, report in enumerate(slides[1:], start=2):
        # 展開後に動かした範囲は、再展開してもそのスライドの位置を残す。
        if report.slide.rois:
            continue
        cloned = []
        for roi in template:
            item = copy.copy(roi)
            item.id = f"{roi.id}-s{index}"
            cloned.append(item)
        report.slide.rois = cloned


def _apply_templates(slide, rule, chunk, slide_number: int, caption_id: str | None, *, overwrite_labels: bool) -> None:
    numbered = {index: asset for index, asset in enumerate(chunk)}
    if rule.title_template and (overwrite_labels or not slide.title.strip()):
        slide.title = render_label(rule.title_template, numbered, slide_number).text
    if caption_id is None:
        return
    template = next((item.template for item in rule.text_templates if item.element_id == caption_id), "")
    if not template:
        return
    text = render_label(template, numbered, slide_number).text
    existing = [item for item in slide.bindings if item.element_id == caption_id]
    if existing and not overwrite_labels and (existing[0].text or "").strip():
        return
    if existing:
        existing[0].text = text
        return
    slide.bindings.append(Binding(element_id=caption_id, text=text))


def _heading_snapshot(slide, frame_ids: set[str]) -> dict[str, Binding]:
    return {item.element_id: item for item in slide.bindings if item.element_id in frame_ids}


def _binding_with_heading(frame_id: str, asset_id: str, previous: Binding | None, master: Binding | None) -> Binding:
    """画像を割り当て直しても、その枠の見出しは残す。見出しが無いスライドは 1 枚目に合わせる。"""
    source = previous if previous is not None else master
    return Binding(
        element_id=frame_id,
        asset_id=asset_id,
        text=None if source is None else source.text,
        text_anchor=None if source is None else source.text_anchor,
        font_pt=None if source is None else source.font_pt,
    )


def _preserved_first_slide(slide, frames, order: dict[str, int]) -> tuple[dict[str, str], int]:
    """1枚目に置いてある画像は残し、続きはその次の画像からにする。"""
    preserved: dict[str, str] = {}
    last_used = -1
    for frame in frames:
        asset_id = next(
            (
                item.asset_id
                for item in slide.bindings
                if item.element_id == frame.id and item.asset_id in order
            ),
            None,
        )
        if asset_id is None:
            continue
        preserved[frame.id] = asset_id
        last_used = max(last_used, order[asset_id])
    return preserved, last_used


def _caption_id(node) -> str | None:
    if isinstance(node, TextNode) and node.role_id == "caption":
        return node.id
    for child in getattr(node, "children", []) or []:
        found = _caption_id(child)
        if found:
            return found
    return None


def _contain_frames(node) -> list[ImageFrameNode]:
    found: list[ImageFrameNode] = []

    def walk(current) -> None:
        if isinstance(current, ImageFrameNode) and current.fit_mode == FitMode.CONTAIN:
            found.append(current)
            return
        for child in getattr(current, "children", []) or []:
            walk(child)

    walk(node)
    return found
