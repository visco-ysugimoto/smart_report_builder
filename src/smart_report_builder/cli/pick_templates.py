"""展開時に差し込むタイトル・見解のテンプレートを保存する。

AssignmentRule の title_template と text_templates へ書く。本文は caption 枠。
"""

from __future__ import annotations

import argparse
import sys

from smart_report_builder import roi_edit
from smart_report_builder.models import AssignmentRule, FrameRef, TextTemplate, TextNode
from smart_report_builder.ordered_assignment import normalize_rule, render_label, set_assignment_rule


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="set-templates",
        description="Store the expansion title / finding templates on the master",
    )
    parser.add_argument("project")
    parser.add_argument("--title", default="")
    parser.add_argument("--caption", default="")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = roi_edit.load_project(args.project)
        _store(project, title=args.title, caption=args.caption)
        roi_edit._save_outputs(project, args.project, args.layout, args.pptx, record_undo=True)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("templates set")
    return 0


def _store(project, *, title: str, caption: str) -> None:
    rule = project.content_master.assignment_rule or AssignmentRule()
    templates = list(rule.text_templates)
    caption_node = _caption_node(project.content_master.root)
    if caption_node is not None:
        templates = [t for t in templates if t.element_id != caption_node.id]
        if caption.strip():
            templates.append(TextTemplate(element_id=caption_node.id, template=caption))
    rule.title_template = title
    rule.text_templates = templates
    # pattern が空のときは、現在の通常画像枠から 1 対 1 のパターンを作る
    if not rule.pattern:
        frames = _contain_frame_ids(project.content_master.root)
        rule.pattern = [
            FrameRef(
                element_id=element_id,
                frame_index=index,
                list_by="position",
                list_key="1",
                item_number=index + 1,
            )
            for index, element_id in enumerate(frames)
        ]
        rule.per_slide = max(len(rule.pattern), 1)
        rule.step = max(len(rule.pattern), 1)
    set_assignment_rule(project, normalize_rule(rule))
    _apply_preview_title(project, title)


def _apply_preview_title(project, title: str) -> None:
    """テンプレートを、今見ているスライドのタイトルにしてプレビューへ出す。"""
    template = title.strip()
    design = project.design_master
    if not template:
        project.slide.title = design.page_title if design.orientation else ""
        return
    assets = {asset.id: asset for asset in project.assets}
    numbered = {}
    for index, frame_id in enumerate(_contain_frame_ids(project.content_master.root)):
        binding = next(
            (
                item
                for item in project.slide.bindings
                if item.element_id == frame_id and item.asset_id
            ),
            None,
        )
        numbered[index] = None if binding is None else assets.get(binding.asset_id)
    number = 1
    for index, item in enumerate(project.report_slides, start=1):
        if item.id == project.active_slide_id:
            number = index
            break
    rendered = render_label(template, numbered, number, assets=project.assets).text.strip()
    project.slide.title = rendered or template


def _caption_node(node) -> TextNode | None:
    if isinstance(node, TextNode) and node.role_id == "caption":
        return node
    for child in getattr(node, "children", []) or []:
        found = _caption_node(child)
        if found is not None:
            return found
    return None


def _contain_frame_ids(node) -> list[str]:
    from smart_report_builder.models import FitMode, ImageFrameNode

    found: list[str] = []

    def walk(current) -> None:
        if isinstance(current, ImageFrameNode) and current.fit_mode == FitMode.CONTAIN:
            found.append(current.id)
            return
        for child in getattr(current, "children", []) or []:
            walk(child)

    walk(node)
    return found
