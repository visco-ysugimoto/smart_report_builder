"""1 枚目の型（content_master のルート）を、プリセット名から組み直す。

bindings は役割を保つため、同じ element_id の枠が残る場合だけ維持する。
"""

from __future__ import annotations

import argparse
import sys

from smart_report_builder import roi_edit
from smart_report_builder.models import (
    GAP_PT,
    TEXT_HEIGHT_PT,
    Binding,
    FitMode,
    GridNode,
    ImageFrameNode,
    StackDirection,
    StackNode,
    TextNode,
)


_PRESETS = {
    "horizontal-2": {
        "arrangement": "horizontal",
        "roles": ["image", "image"],
    },
    "horizontal-3": {
        "arrangement": "horizontal",
        "roles": ["image", "image", "image"],
    },
    "horizontal-4": {
        "arrangement": "horizontal",
        "roles": ["image", "image", "image", "image"],
    },
    "vertical-2": {
        "arrangement": "vertical",
        "roles": ["image", "image"],
    },
    "vertical-3": {
        "arrangement": "vertical",
        "roles": ["image", "image", "image"],
    },
    "grid-2x2": {
        "arrangement": "grid",
        "columns": 2,
        "roles": ["image", "image", "image", "image"],
    },
    "grid-2x3": {
        "arrangement": "grid",
        "columns": 3,
        "roles": ["image"] * 6,
    },
    "grid-3x2": {
        "arrangement": "grid",
        "columns": 2,
        "roles": ["image"] * 6,
    },
    "grid-3x3": {
        "arrangement": "grid",
        "columns": 3,
        "roles": ["image"] * 9,
    },
    "overall-zoom": {
        "arrangement": "horizontal",
        "roles": ["image", "zoom"],
    },
    "overall-compare-2": {
        "arrangement": "horizontal",
        "roles": ["image", "image", "image"],
    },
    "overall-compare-3": {
        "arrangement": "horizontal",
        "roles": ["image", "image", "image", "image"],
    },
}

_ROLE_LABELS = {
    "image": "画像",
    "zoom": "拡大画像",
}


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="pick-layout",
        description="Rebuild the first slide's layout from a preset",
    )
    parser.add_argument("project")
    parser.add_argument("--preset", required=True, choices=sorted(_PRESETS))
    parser.add_argument("--caption", default="")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = roi_edit.load_project(args.project)
        _apply_preset(project, args.preset, args.caption)
        roi_edit._save_outputs(project, args.project, args.layout, args.pptx, record_undo=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"preset {args.preset}")
    return 0


def _apply_preset(project, preset: str, caption: str) -> None:
    spec = _PRESETS[preset]
    roles = spec["roles"]
    frames: list[ImageFrameNode] = []
    taken: set[str] = set()
    for index, role in enumerate(roles, start=1):
        label = _display_name(role, index, taken)
        taken.add(label)
        fit = FitMode.ROI if role == "zoom" else FitMode.CONTAIN
        frames.append(
            ImageFrameNode(
                id=f"frame-{index}",
                role_id=role,
                display_name=label,
                fit_mode=fit,
            )
        )
    arrangement = spec["arrangement"]
    if arrangement == "grid":
        image_block = GridNode(
            id="grid-frames",
            columns=spec.get("columns", 2),
            gap_pt=GAP_PT,
            children=list(frames),
        )
    else:
        direction = (
            StackDirection.HORIZONTAL if arrangement == "horizontal" else StackDirection.VERTICAL
        )
        image_block = StackNode(
            id="stack-frames",
            direction=direction,
            gap_pt=GAP_PT,
            children=list(frames),
            track_aspect=False,
        )
    caption_text = caption or _existing_caption(project) or ""
    caption_place = _existing_caption_place(project)
    previous = _find_caption(project.content_master.root)
    caption_node = TextNode(
        id="text-caption",
        role_id="caption",
        display_name="説明",
        text=caption_text,
        height_pt=TEXT_HEIGHT_PT,
        place=caption_place,
        shown=True if previous is None else previous.shown,
        font_pt=16.0 if previous is None else previous.font_pt,
    )
    children = [caption_node, image_block] if caption_place == "before" else [image_block, caption_node]
    root = StackNode(
        id="stack-root",
        direction=StackDirection.VERTICAL,
        gap_pt=GAP_PT,
        children=children,
    )
    master = project.content_master
    master.root = root
    master.name = _preset_label(preset)
    # bindings は枠 ID が維持される範囲で残す
    frame_ids = {frame.id for frame in frames}
    for slide in _slides(project):
        slide.bindings = [b for b in slide.bindings if b.element_id in frame_ids or b.element_id == "text-caption"]
        slide.rois = []


def _slides(project):
    if project.report_slides:
        return [item.slide for item in project.report_slides]
    return [project.slide]


def _display_name(role: str, index: int, taken: set[str]) -> str:
    base = _ROLE_LABELS.get(role, "画像")
    if role == "image":
        candidate = f"画像{index}"
    else:
        candidate = base
    if candidate not in taken:
        return candidate
    number = 2
    while f"{candidate}{number}" in taken:
        number += 1
    return f"{candidate}{number}"


def _find_caption(node) -> TextNode | None:
    if isinstance(node, TextNode) and node.role_id == "caption":
        return node
    for child in getattr(node, "children", []) or []:
        found = _find_caption(child)
        if found is not None:
            return found
    return None


def _existing_caption_place(project) -> str:
    def find(node) -> str:
        if isinstance(node, TextNode) and node.role_id == "caption":
            return node.place
        for child in getattr(node, "children", []) or []:
            place = find(child)
            if place:
                return place
        return ""

    found = find(project.content_master.root)
    return found if found in {"before", "after"} else "after"


def _existing_caption(project) -> str:
    def find(node) -> str:
        if isinstance(node, TextNode) and node.role_id == "caption":
            return node.text
        for child in getattr(node, "children", []) or []:
            text = find(child)
            if text:
                return text
        return ""

    return find(project.content_master.root)


def _preset_label(preset: str) -> str:
    return {
        "horizontal-2": "画像2枚 横並び",
        "horizontal-3": "画像3枚 横並び",
        "horizontal-4": "画像4枚 横並び",
        "vertical-2": "画像2枚 縦並び",
        "vertical-3": "画像3枚 縦並び",
        "grid-2x2": "画像4枚 グリッド",
        "grid-2x3": "画像6枚 グリッド(2×3)",
        "grid-3x2": "画像6枚 グリッド(3×2)",
        "grid-3x3": "画像9枚 グリッド",
        "overall-zoom": "画像と拡大",
        "overall-compare-2": "画像3枚 横並び",
        "overall-compare-3": "画像4枚 横並び",
    }[preset]
