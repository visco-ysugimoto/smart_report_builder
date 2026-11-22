"""展開後の個別スライドを更新する。タイトル、見解、画像の差し替え、枠の役割を扱う。"""

from __future__ import annotations

import argparse
import sys

from smart_report_builder import roi_edit
from smart_report_builder.models import (
    Binding,
    CoordSpace,
    FitMode,
    ImageFrameNode,
    Project,
    Rect,
    ReportSlide,
    Roi,
    SlideInstance,
    StackNode,
    TextNode,
)
from smart_report_builder.practical import record_roi_move, set_image_frame_kind


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="edit-slide",
        description="Update a single slide: title, caption, binding, role",
    )
    parser.add_argument("project")
    parser.add_argument("--slide")
    parser.add_argument("--title")
    parser.add_argument("--caption")
    parser.add_argument("--bind", nargs=2, metavar=("FRAME_ID", "ASSET_ID"))
    parser.add_argument("--unbind")
    parser.add_argument("--role", nargs=2, metavar=("FRAME_ID", "ROLE"))
    parser.add_argument("--zoom-from", nargs=2, metavar=("ZOOM_ID", "SOURCE_ID"))
    parser.add_argument("--zoom-move", nargs=3, metavar=("ZOOM_ID", "X", "Y"))
    parser.add_argument("--zoom-rect", nargs=5, metavar=("ZOOM_ID", "X", "Y", "WIDTH", "HEIGHT"))
    parser.add_argument("--heading", nargs=2, metavar=("FRAME_ID", "TEXT"))
    parser.add_argument("--heading-place", nargs=2, metavar=("FRAME_ID", "PLACE"))
    parser.add_argument("--heading-size", nargs=2, metavar=("FRAME_ID", "PT"))
    parser.add_argument("--caption-place", choices=("above", "below"))
    parser.add_argument("--caption-use", choices=("on", "off"))
    parser.add_argument("--text-size", nargs=2, metavar=("TEXT_ID", "PT"))
    parser.add_argument("--add-text", action="store_true")
    parser.add_argument("--text", default="テキスト")
    parser.add_argument("--text-box", nargs=5, metavar=("TEXT_ID", "X", "Y", "W", "H"))
    parser.add_argument("--text-body", nargs=2, metavar=("TEXT_ID", "TEXT"))
    parser.add_argument("--remove-text")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = roi_edit.load_project(args.project)
        slide = _resolve_slide(project, args.slide)
        if args.title is not None:
            slide.title = args.title
        if args.caption is not None:
            _set_caption(project, slide, args.caption)
        if args.bind:
            frame_id, asset_id = args.bind
            if not any(asset.id == asset_id for asset in project.assets):
                raise ValueError("割当先の素材が見つからない")
            _set_binding(slide, frame_id, asset_id=asset_id)
        if args.unbind:
            _clear_binding(slide, args.unbind)
        if args.role:
            frame_id, role = args.role
            # 役割は master に属するため、slide を 1 枚だけ編集するときにも
            # master を更新して全スライドに影響する点に注意。
            set_image_frame_kind(project, frame_id, role)
        if args.zoom_from:
            zoom_id, source_id = args.zoom_from
            _link_zoom(project, slide, zoom_id, source_id)
        if args.zoom_move:
            zoom_id, raw_x, raw_y = args.zoom_move
            _move_zoom(project, slide, zoom_id, float(raw_x), float(raw_y))
        if args.zoom_rect:
            zoom_id, raw_x, raw_y, raw_width, raw_height = args.zoom_rect
            _move_zoom(
                project,
                slide,
                zoom_id,
                float(raw_x),
                float(raw_y),
                width=float(raw_width),
                height=float(raw_height),
            )
        if args.heading:
            frame_id, text = args.heading
            _set_binding(slide, frame_id, text=text)
        if args.heading_place:
            frame_id, place = args.heading_place
            if place not in {"above", "below"}:
                raise ValueError("見出しの位置は上か下です")
            _set_binding(slide, frame_id, text_anchor=place)
        if args.heading_size:
            frame_id, raw_size = args.heading_size
            _set_binding(slide, frame_id, font_pt=_text_size(raw_size))
        if args.caption_place:
            _set_caption_place(project, args.caption_place)
        if args.caption_use:
            _set_caption_shown(project, args.caption_use == "on")
        if args.text_size:
            text_id, raw_size = args.text_size
            _set_text_size(project, text_id, _text_size(raw_size))
        if args.add_text:
            _add_free_text(project, args.text)
        if args.text_box:
            text_id, raw_x, raw_y, raw_w, raw_h = args.text_box
            _move_free_text(
                project,
                text_id,
                float(raw_x),
                float(raw_y),
                float(raw_w),
                float(raw_h),
            )
        if args.text_body:
            text_id, body = args.text_body
            _set_free_text(project, slide, text_id, body)
        if args.remove_text:
            _remove_free_text(project, args.remove_text)
        roi_edit._save_outputs(project, args.project, args.layout, args.pptx, record_undo=True)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"updated {slide.id}")
    return 0


def _resolve_slide(project: Project, slide_id: str | None) -> SlideInstance:
    if project.report_slides:
        if slide_id:
            item = next((s for s in project.report_slides if s.id == slide_id), None)
            if item is None:
                raise ValueError("スライドが見つからない")
            return item.slide
        return project.slide if project.active_slide_id is None else _active(project).slide
    return project.slide


def _active(project: Project) -> ReportSlide:
    for item in project.report_slides:
        if item.id == project.active_slide_id:
            return item
    return project.report_slides[0]


def _set_caption(project: Project, slide: SlideInstance, text: str) -> None:
    caption_id = _caption_element_id(project)
    if caption_id is None:
        raise ValueError("説明枠がありません")
    _set_binding(slide, caption_id, text=text)


def _caption_element_id(project: Project) -> str | None:
    from smart_report_builder.models import TextNode

    def walk(node) -> str | None:
        if isinstance(node, TextNode) and node.role_id == "caption":
            return node.id
        for child in getattr(node, "children", []) or []:
            found = walk(child)
            if found:
                return found
        return None

    return walk(project.content_master.root)


def _set_binding(
    slide: SlideInstance,
    element_id: str,
    *,
    asset_id: str | None = None,
    text: str | None = None,
    text_anchor: str | None = None,
    font_pt: float | None = None,
) -> None:
    existing = [b for b in slide.bindings if b.element_id == element_id]
    if not existing:
        slide.bindings.append(
            Binding(
                element_id=element_id,
                asset_id=asset_id,
                text=text,
                text_anchor=text_anchor,
                font_pt=font_pt,
            )
        )
        return
    binding = existing[0]
    if asset_id is not None:
        binding.asset_id = asset_id
    if text is not None:
        binding.text = text
    if text_anchor is not None:
        binding.text_anchor = text_anchor
    if font_pt is not None:
        binding.font_pt = font_pt


_TEXT_SIZES = {12.0, 14.0, 16.0, 18.0, 22.0, 28.0, 36.0}


def _text_size(raw: str) -> float:
    try:
        size = float(raw)
    except ValueError as exc:
        raise ValueError("文字サイズは 12, 14, 16, 18, 22, 28, 36 のいずれかです") from exc
    if size not in _TEXT_SIZES:
        raise ValueError("文字サイズは 12, 14, 16, 18, 22, 28, 36 のいずれかです")
    return size


def _set_caption_place(project: Project, place: str) -> None:
    node = _find_caption(project.content_master.root)
    if node is None:
        raise ValueError("説明枠がありません")
    node.place = "before" if place == "above" else "after"


def _set_caption_shown(project: Project, shown: bool) -> None:
    node = _find_caption(project.content_master.root)
    if node is None:
        raise ValueError("説明枠がありません")
    node.shown = shown


def _set_text_size(project: Project, text_id: str, size: float) -> None:
    node = _find_text(project.content_master.root, text_id)
    if node is None:
        raise ValueError("テキストが見つからない")
    node.font_pt = size


def _clear_binding(slide: SlideInstance, element_id: str) -> None:
    slide.bindings = [b for b in slide.bindings if b.element_id != element_id]


def _link_zoom(project: Project, slide: SlideInstance, zoom_id: str, source_id: str) -> None:
    """拡大枠がどの画像枠のどの範囲を見せるかを決める。

    範囲は元画像の中央 50% を初期値にする。拡大元を変えたときだけ範囲を戻す。
    """
    if source_id == "-":
        slide.rois = [roi for roi in slide.rois if roi.zoom_element_id != zoom_id]
        return
    zoom = _find_frame(project.content_master.root, zoom_id)
    source = _find_frame(project.content_master.root, source_id)
    if zoom is None or zoom.fit_mode != FitMode.ROI:
        raise ValueError("拡大画像の枠を選んでください")
    if source is None or source.fit_mode != FitMode.CONTAIN:
        raise ValueError("拡大元は通常の画像枠です")
    if zoom.id == source.id:
        raise ValueError("拡大元に同じ枠は選べません")
    current = next((roi for roi in slide.rois if roi.zoom_element_id == zoom.id), None)
    others = [roi for roi in slide.rois if roi.zoom_element_id != zoom.id]
    if current is None:
        current = Roi(
            id=_next_roi_id(project),
            name=f"{source.display_name}の拡大",
            source_element_id=source.id,
            zoom_element_id=zoom.id,
            x=0.25,
            y=0.25,
            width=0.5,
            height=0.5,
            coord_space=CoordSpace.NORMALIZED,
        )
    else:
        if current.source_element_id != source.id:
            current.x, current.y, current.width, current.height = 0.25, 0.25, 0.5, 0.5
        current.source_element_id = source.id
        current.zoom_element_id = zoom.id
        current.name = f"{source.display_name}の拡大"
    slide.rois = [*others, current]


def _move_zoom(
    project: Project,
    slide: SlideInstance,
    zoom_id: str,
    x: float,
    y: float,
    *,
    width: float | None = None,
    height: float | None = None,
) -> None:
    """拡大範囲を、元画像に対する正規化座標で置き換える。幅と高さの省略時は現状を保つ。"""
    roi = next((item for item in slide.rois if item.zoom_element_id == zoom_id), None)
    if roi is None:
        raise ValueError("拡大範囲がありません")
    if roi.coord_space != CoordSpace.NORMALIZED:
        raise ValueError("この拡大範囲は移動できません")
    roi.width = _clamp_size(roi.width if width is None else width)
    roi.height = _clamp_size(roi.height if height is None else height)
    roi.x = _clamp_origin(x, roi.width)
    roi.y = _clamp_origin(y, roi.height)
    record_roi_move(project, roi)


def _clamp_origin(value: float, size: float) -> float:
    limit = max(0.0, 1.0 - size)
    return min(max(0.0, value), limit)


def _clamp_size(value: float) -> float:
    return min(max(_MIN_ZOOM_SIZE, value), 1.0)


_MIN_ZOOM_SIZE = 0.02


def _add_free_text(project: Project, text: str) -> None:
    root = project.content_master.root
    if not isinstance(root, StackNode):
        raise ValueError("この配置にはテキストを追加できません")
    number = 1
    while _find_text(root, f"text-free-{number}") is not None:
        number += 1
    root.children.append(
        TextNode(
            id=f"text-free-{number}",
            role_id="note",
            display_name="テキスト",
            text=text,
            height_pt=28,
            free_rect=Rect(0.58, 0.06, 0.34, 0.12),
        )
    )


def _move_free_text(project: Project, text_id: str, x: float, y: float, width: float, height: float) -> None:
    node = _find_text(project.content_master.root, text_id)
    if node is None:
        raise ValueError("テキストが見つからない")
    from smart_report_builder.layout import _content_bounds

    bounds = _content_bounds(project.design_master)
    if bounds.width <= 0 or bounds.height <= 0:
        raise ValueError("テキストを置く領域がありません")
    node.free_rect = Rect(
        (x - bounds.x) / bounds.width,
        (y - bounds.y) / bounds.height,
        width / bounds.width,
        height / bounds.height,
    )


def _remove_free_text(project: Project, text_id: str) -> None:
    node = _find_text(project.content_master.root, text_id)
    if node is None or node.role_id != "note":
        raise ValueError("削除できるのは追加したテキストです")
    if not _detach_text(project.content_master.root, text_id):
        raise ValueError("テキストが見つからない")
    slides = [item.slide for item in project.report_slides] or [project.slide]
    if all(item is not project.slide for item in slides):
        slides.append(project.slide)
    for current in slides:
        current.bindings = [item for item in current.bindings if item.element_id != text_id]


def _detach_text(node, text_id: str) -> bool:
    children = getattr(node, "children", None)
    if not children:
        return False
    for child in list(children):
        if isinstance(child, TextNode) and child.id == text_id:
            children.remove(child)
            return True
        if _detach_text(child, text_id):
            return True
    return False


def _set_free_text(project: Project, slide: SlideInstance, text_id: str, text: str) -> None:
    node = _find_text(project.content_master.root, text_id)
    if node is None:
        raise ValueError("テキストが見つからない")
    node.text = text
    _set_binding(slide, text_id, text=text)


def _find_caption(node) -> TextNode | None:
    if isinstance(node, TextNode) and node.role_id == "caption":
        return node
    for child in getattr(node, "children", []) or []:
        found = _find_caption(child)
        if found is not None:
            return found
    return None


def _find_text(node, text_id: str) -> TextNode | None:
    if isinstance(node, TextNode) and node.id == text_id:
        return node
    for child in getattr(node, "children", []) or []:
        found = _find_text(child, text_id)
        if found is not None:
            return found
    return None


def _find_frame(node, frame_id: str) -> ImageFrameNode | None:
    if isinstance(node, ImageFrameNode) and node.id == frame_id:
        return node
    for child in getattr(node, "children", []) or []:
        found = _find_frame(child, frame_id)
        if found is not None:
            return found
    return None


def _next_roi_id(project: Project) -> str:
    slides = [item.slide for item in project.report_slides] or [project.slide]
    used = {roi.id for slide in slides for roi in slide.rois}
    number = 1
    while f"roi-{number}" in used:
        number += 1
    return f"roi-{number}"
