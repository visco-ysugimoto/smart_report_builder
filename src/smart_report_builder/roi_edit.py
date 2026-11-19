"""既存 ROI の更新、複製、一つ戻す操作、やり直しと、新しい矩形 ROI の追加。

通常表示の画像枠へ、既存の画像ファイルを割り当てる操作も含む。
プレビューは正規化座標を渡す。既存 ROI の座標方式は変えない。
新しい ROI は正規化座標で保存する。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from smart_report_builder.layout import layout_slide
from smart_report_builder.models import (
    GAP_PT,
    SCHEMA_VERSION,
    Asset,
    Binding,
    CoordSpace,
    Element,
    FitMode,
    GridNode,
    ImageFrameNode,
    LayoutDefinition,
    Project,
    Rect,
    ReportSlide,
    Roi,
    SlideInstance,
    StackDirection,
    StackNode,
    TextNode,
)
from smart_report_builder.imaging_template import (
    DEFAULT_PAGE_TITLE,
    imaging_slide_names_at,
    materialize_template,
    read_imaging_template,
    render_chrome,
)
from smart_report_builder.pptx_writer import write_pptx_slides
from smart_report_builder.project_store import (
    load_layout_result,
    load_project,
    save_layout_result,
    save_project,
)
from smart_report_builder.project_factory import create_report
from smart_report_builder.practical import record_roi_move

_EPS = 1e-6
_ROUNDING = 1e-4
_DUPLICATE_SHIFT_NORMALIZED = 0.04
_DUPLICATE_SHIFT_PX = 16.0
_NOTE_EPS = 1e-4
_HISTORY_LIMIT = 20


def apply_normalized_roi(
    project: Project,
    roi_id: str,
    x: float,
    y: float,
    width: float,
    height: float,
) -> None:
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    x, y, width, height = _absorb_rounding(x, y, width, height)
    if not _inside_unit(x, y, width, height):
        raise ValueError("ROI が元画像の外です")
    if roi.coord_space == CoordSpace.PIXEL:
        asset = _source_asset(project, roi)
        roi.x = x * asset.width_px
        roi.y = y * asset.height_px
        roi.width = width * asset.width_px
        roi.height = height * asset.height_px
        record_roi_move(project, roi)
        return
    if roi.coord_space != CoordSpace.NORMALIZED:
        raise ValueError("未対応の ROI 座標方式")
    roi.x = x
    roi.y = y
    roi.width = width
    roi.height = height
    record_roi_move(project, roi)


def _absorb_rounding(x: float, y: float, width: float, height: float) -> tuple[float, float, float, float]:
    if -_ROUNDING <= x < 0:
        x = 0
    if -_ROUNDING <= y < 0:
        y = 0
    if 1 < x + width <= 1 + _ROUNDING:
        width = 1 - x
    if 1 < y + height <= 1 + _ROUNDING:
        height = 1 - y
    return x, y, width, height


def _inside_unit(x: float, y: float, width: float, height: float) -> bool:
    return (
        width > _EPS
        and height > _EPS
        and x >= -_EPS
        and y >= -_EPS
        and x + width <= 1 + _EPS
        and y + height <= 1 + _EPS
    )


def add_normalized_roi(
    project: Project,
    source_element_id: str,
    x: float,
    y: float,
    width: float,
    height: float,
) -> tuple[str, str]:
    """新しい ROI を追加する。戻り値は ID と拡大枠の連動結果。"""
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    x, y, width, height = _absorb_rounding(x, y, width, height)
    if not _inside_unit(x, y, width, height):
        raise ValueError("ROI が元画像の外です")
    frame = _contain_frame(project, source_element_id)
    _source_asset_for(project, frame.id)
    roi_id = _next_roi_id(project)
    zoom_ids = [
        item.id for item in _image_frames(project.content_master.root) if item.fit_mode == FitMode.ROI
    ]
    used = {item.zoom_element_id for item in project.slide.rois if item.zoom_element_id is not None}
    label = zoom_link_label(zoom_ids, used)
    project.slide.rois.append(
        Roi(
            id=roi_id,
            name=f"ROI {roi_id.removeprefix('roi-')}",
            source_element_id=frame.id,
            zoom_element_id=None if label in {"-", "ambiguous"} else label,
            x=x,
            y=y,
            width=width,
            height=height,
            coord_space=CoordSpace.NORMALIZED,
        )
    )
    return roi_id, label


def set_roi_zoom(
    project: Project,
    roi_id: str,
    *,
    linked: bool,
    zoom_element_id: str | None = None,
) -> tuple[str, str | None]:
    """選択した ROI を指定の拡大枠へ連動するか、連動を外す。

    拡大枠の指定がないときは、枠がちょうど一つの場合だけそこへ連動する。
    戻り値は拡大枠の ID（外したときは ``-``）と、その枠から外した別 ROI の ID。
    同じ拡大枠へ複数の ROI は載せない。座標は変えない。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    if not linked:
        roi.zoom_element_id = None
        return "-", None
    zoom_ids = [
        item.id for item in _image_frames(project.content_master.root) if item.fit_mode == FitMode.ROI
    ]
    if zoom_element_id is None:
        if not zoom_ids:
            raise ValueError("拡大枠がないため連動できません")
        if len(zoom_ids) != 1:
            raise ValueError("拡大枠が複数あるため、連動先を指定してください")
        target = zoom_ids[0]
    elif zoom_element_id not in zoom_ids:
        raise ValueError("指定した要素は拡大枠ではありません")
    else:
        target = zoom_element_id
    replaced: str | None = None
    for other in project.slide.rois:
        if other.id != roi.id and other.zoom_element_id == target:
            other.zoom_element_id = None
            replaced = other.id
    roi.zoom_element_id = target
    return target, replaced


def arrange_roi_zooms(project: Project, arrangement: str = "horizontal") -> list[str]:
    """ROI ごとの拡大画像を、全体画像の並びに続けて配置する。

    すでにその ROI だけの拡大枠があるときはその枠を使う。
    ないときと、同じ枠を複数の ROI が指しているときは新しい枠を作る。
    ROI の矩形は変えない。戻り値は並べた拡大枠の ID。
    """
    if arrangement not in {"horizontal", "vertical", "grid"}:
        raise ValueError("配置は縦、横、格子のいずれかです")
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    if not project.slide.rois:
        raise ValueError("並べる ROI がありません")
    root = project.content_master.root
    if not isinstance(root, StackNode):
        raise ValueError("この配置には拡大画像を並べられません")

    by_id = {item.id: item for item in _image_frames(root)}
    used_ids = set(_element_ids(root))
    claimed: set[str] = set()
    ordered: list[ImageFrameNode] = []
    for roi in project.slide.rois:
        current = by_id.get(roi.zoom_element_id) if roi.zoom_element_id else None
        if current is not None and current.fit_mode == FitMode.ROI and current.id not in claimed:
            claimed.add(current.id)
            ordered.append(current)
            continue
        frame = ImageFrameNode(
            id=_next_numbered_id("frame-", used_ids),
            role_id="zoom",
            display_name=_zoom_display_name(roi),
            fit_mode=FitMode.ROI,
        )
        used_ids.add(frame.id)
        by_id[frame.id] = frame
        roi.zoom_element_id = frame.id
        claimed.add(frame.id)
        ordered.append(frame)

    for frame in ordered:
        _detach_image_frame(root, frame.id)
    _prune_empty_containers(root)
    for frame in ordered:
        frame.free_rect = None
    _insert_zoom_block(root, _zoom_arrangement(arrangement, ordered))
    return [item.id for item in ordered]


def set_image_frame_rect(
    project: Project,
    element_id: str,
    x: float,
    y: float,
    width: float,
    height: float,
) -> str:
    """画像枠を、親の並びの中の正規化矩形へ変える。

    まだ個別の大きさを持たない枠は、今の位置を記録してから対象だけ動かす。
    画像そのものの縦横比は変えず、枠の中へ contain で収める。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    x, y, width, height = _absorb_rounding(x, y, width, height)
    if not _inside_unit(x, y, width, height) or width < 0.02 or height < 0.02:
        raise ValueError("画像枠が並びの外か、小さすぎます")
    parent = _image_frame_parent(project.content_master.root, element_id)
    if not isinstance(parent, (StackNode, GridNode)):
        raise ValueError("この画像枠は変形できません")
    frames = [child for child in parent.children if isinstance(child, ImageFrameNode)]
    target = next(frame for frame in frames if frame.id == element_id)
    if all(frame.free_rect is None for frame in frames):
        _remember_current_frame_rects(project, frames)
    elif target.free_rect is None:
        target.free_rect = Rect(0, 0, 1, 1)
    target.free_rect = Rect(x, y, width, height)
    return element_id


def _image_frame_parent(node: Element, element_id: str) -> StackNode | GridNode | None:
    if not isinstance(node, (StackNode, GridNode)):
        return None
    for child in node.children:
        if isinstance(child, ImageFrameNode) and child.id == element_id:
            return node
        found = _image_frame_parent(child, element_id)
        if found is not None:
            return found
    return None


def _remember_current_frame_rects(project: Project, frames: list[ImageFrameNode]) -> None:
    placed = {item.element_id: item for item in layout_slide(project).elements}
    boxes = []
    for frame in frames:
        element = placed.get(frame.id)
        if element is None or element.kind != "image_frame":
            raise ValueError("画像枠の位置がありません")
        boxes.append(element.frame)
    left = min(box.x for box in boxes)
    top = min(box.y for box in boxes)
    right = max(box.x + box.width for box in boxes)
    bottom = max(box.y + box.height for box in boxes)
    span_w = right - left
    span_h = bottom - top
    if span_w <= _EPS or span_h <= _EPS:
        raise ValueError("画像枠の範囲がありません")
    for frame, box in zip(frames, boxes, strict=True):
        frame.free_rect = Rect(
            (box.x - left) / span_w,
            (box.y - top) / span_h,
            box.width / span_w,
            box.height / span_h,
        )


def _zoom_display_name(roi: Roi) -> str:
    name = roi.name.strip() or roi.id
    if name.endswith("の拡大"):
        return name
    return f"{name}の拡大"


def _next_numbered_id(prefix: str, used: set[str]) -> str:
    number = 1
    while f"{prefix}{number}" in used:
        number += 1
    return f"{prefix}{number}"


def _zoom_arrangement(arrangement: str, frames: list[ImageFrameNode]) -> StackNode | GridNode:
    if arrangement == "grid":
        return GridNode(
            id="grid-zooms",
            columns=1 if len(frames) <= 1 else 2,
            gap_pt=GAP_PT,
            children=list(frames),
        )
    direction = StackDirection.VERTICAL if arrangement == "vertical" else StackDirection.HORIZONTAL
    return StackNode(
        id="stack-zooms",
        direction=direction,
        gap_pt=GAP_PT,
        children=list(frames),
    )


def _insert_zoom_block(root: StackNode, block: StackNode | GridNode) -> None:
    for index, child in enumerate(root.children):
        if child.id in {"stack-zooms", "grid-zooms"}:
            root.children[index] = block
            return
    image_at: int | None = None
    text_at: int | None = None
    for index, child in enumerate(root.children):
        if image_at is None and isinstance(child, (StackNode, GridNode)) and _image_frames(child):
            image_at = index
        if text_at is None and isinstance(child, TextNode):
            text_at = index
    if image_at is not None:
        root.children.insert(image_at + 1, block)
    elif text_at is not None:
        root.children.insert(text_at, block)
    else:
        root.children.append(block)


def _detach_image_frame(node: Element, element_id: str) -> ImageFrameNode | None:
    if not isinstance(node, (StackNode, GridNode)):
        return None
    for index, child in enumerate(node.children):
        if isinstance(child, ImageFrameNode) and child.id == element_id:
            return node.children.pop(index)
        found = _detach_image_frame(child, element_id)
        if found is not None:
            return found
    return None


def _prune_empty_containers(node: Element) -> None:
    if not isinstance(node, (StackNode, GridNode)):
        return
    kept: list[Element] = []
    for child in node.children:
        _prune_empty_containers(child)
        if isinstance(child, (StackNode, GridNode)) and not child.children:
            continue
        kept.append(child)
    node.children = kept


def _element_ids(node: Element) -> list[str]:
    found = [node.id]
    if isinstance(node, (StackNode, GridNode)):
        for child in node.children:
            found.extend(_element_ids(child))
    return found


def rename_roi(project: Project, roi_id: str, name: str) -> str:
    """ROI の表示名だけを変える。座標、ID、拡大枠への連動は変えない。"""
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    cleaned = name.strip()
    if not cleaned or any(character in cleaned for character in "\r\n\t"):
        raise ValueError("ROI の名前が空です")
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    roi.name = cleaned
    return cleaned


def duplicate_roi(project: Project, roi_id: str) -> tuple[str, bool]:
    """ROI を複製する。戻り値は新しい ID と、右下へずらしたかどうか。

    元の座標、名前、拡大枠への連動は変えない。複製は連動を引き継がない。
    元画像の中に余地があるときだけ、同じ大きさのまま右下へ少しずらす。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    source = next((item for item in project.slide.rois if item.id == roi_id), None)
    if source is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    new_id = _next_roi_id(project)
    x, y = _duplicate_origin(project, source)
    project.slide.rois.append(
        Roi(
            id=new_id,
            name=f"{source.name} のコピー",
            source_element_id=source.source_element_id,
            x=x,
            y=y,
            width=source.width,
            height=source.height,
            zoom_element_id=None,
            coord_space=source.coord_space,
            note=source.note,
            note_dx=source.note_dx,
            note_dy=source.note_dy,
        )
    )
    return new_id, (x, y) != (source.x, source.y)


def _duplicate_origin(project: Project, roi: Roi) -> tuple[float, float]:
    if roi.coord_space == CoordSpace.PIXEL:
        asset = _source_asset(project, roi)
        return (
            _shift_axis(roi.x, roi.width, asset.width_px, _DUPLICATE_SHIFT_PX),
            _shift_axis(roi.y, roi.height, asset.height_px, _DUPLICATE_SHIFT_PX),
        )
    if roi.coord_space != CoordSpace.NORMALIZED:
        raise ValueError("未対応の ROI 座標方式")
    return (
        _shift_axis(roi.x, roi.width, 1, _DUPLICATE_SHIFT_NORMALIZED),
        _shift_axis(roi.y, roi.height, 1, _DUPLICATE_SHIFT_NORMALIZED),
    )


def _shift_axis(origin: float, size: float, limit: float, step: float) -> float:
    room = max(0.0, limit - size)
    moved = min(origin + step, room)
    if moved < origin:
        return origin
    return moved


def set_roi_note(project: Project, roi_id: str, note: str) -> str:
    """ROI の注釈だけを変える。空なら注釈と接続線を出さない。座標と連動は変えない。"""
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    cleaned = note.strip()
    if any(character in cleaned for character in "\r\n\t"):
        raise ValueError("注釈に改行やタブは使えません")
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    roi.note = cleaned
    return cleaned


def set_note_position(project: Project, roi_id: str, x: float, y: float) -> tuple[float, float]:
    """注釈枠の左上をスライドポイントで指定し、自動位置からのずれとして保存する。

    文字、ROI の矩形、拡大枠への連動は変えない。枠がスライドに収まらない指定は拒否する。
    戻り値は保存した横方向と縦方向のずれ。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    if not roi.note.strip():
        raise ValueError("注釈がないため位置を保存できません")
    saved = (roi.note_dx, roi.note_dy)
    roi.note_dx = None
    roi.note_dy = None
    try:
        placed = layout_slide(project)
    finally:
        roi.note_dx, roi.note_dy = saved
    label = next((item for item in placed.elements if item.element_id == f"{roi.id}-note"), None)
    if label is None:
        raise ValueError("注釈が配置されていないため位置を保存できません")
    dx = x - label.frame.x
    dy = y - label.frame.y
    moved = Rect(label.frame.x + dx, label.frame.y + dy, label.frame.width, label.frame.height)
    slide = placed
    if (
        moved.x < -_NOTE_EPS
        or moved.y < -_NOTE_EPS
        or moved.x + moved.width > slide.slide_width_pt + _NOTE_EPS
        or moved.y + moved.height > slide.slide_height_pt + _NOTE_EPS
    ):
        raise ValueError("注釈がスライドの外です")
    roi.note_dx = dx
    roi.note_dy = dy
    return dx, dy


def clear_note_position(project: Project, roi_id: str) -> None:
    """保存した注釈のずれを消し、自動配置へ戻す。文字、矩形、拡大枠への連動は変えない。"""
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    if not roi.note.strip():
        raise ValueError("注釈がないため位置を戻せません")
    if roi.note_dx is None or roi.note_dy is None:
        raise ValueError("注釈はすでに自動位置です")
    roi.note_dx = None
    roi.note_dy = None


def assign_frame_image(project: Project, element_id: str, image_path: str) -> str:
    """通常表示の画像枠へ画像ファイルを割り当てる。

    元ファイルは読み取って寸法を記録するだけで、書き換えない。
    その枠だけが使っている素材は同じ ID のまま差し替える。
    ほかの枠と共有している素材は残し、この枠だけ新しい素材を指す。
    ROI の保存座標と注釈は変えない。戻り値は割り当てた素材 ID。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    frame = next((item for item in _image_frames(project.content_master.root) if item.id == element_id), None)
    if frame is None:
        raise ValueError(f"画像枠が見つからない: {element_id}")
    if frame.fit_mode == FitMode.ROI:
        raise ValueError("拡大枠には素材を直接割り当てられません")
    if frame.fit_mode != FitMode.CONTAIN:
        raise ValueError("この画像枠には素材を割り当てられません")
    path = Path(image_path)
    if not path.is_file():
        raise ValueError("画像ファイルが見つからない")
    width, height = _read_image_size(path)
    matches = [item for item in project.slide.bindings if item.element_id == element_id]
    if len(matches) > 1:
        raise ValueError("この枠の割当が競合しているため変更しません")
    resolved = str(path.resolve())
    if len(matches) == 1 and matches[0].asset_id is not None:
        asset_id = matches[0].asset_id
        asset = next((item for item in project.assets if item.id == asset_id), None)
        users = [item for item in project.slide.bindings if item.asset_id == asset_id]
        if asset is not None and len(users) == 1:
            asset.path = resolved
            asset.width_px = width
            asset.height_px = height
            asset.display_name = path.stem or path.name
            return asset.id
    asset_id = _next_asset_id(project)
    project.assets.append(
        Asset(
            id=asset_id,
            path=resolved,
            width_px=width,
            height_px=height,
            display_name=path.stem or path.name,
        )
    )
    if len(matches) == 1:
        matches[0].asset_id = asset_id
    else:
        project.slide.bindings.append(Binding(element_id=element_id, asset_id=asset_id))
    return asset_id


def clear_frame_image(project: Project, element_id: str) -> None:
    """通常表示の画像枠から素材の割当だけを外す。

    枠、素材の記録、元ファイル、ROI の保存座標は残す。
    ほかの枠が同じ素材を使っている場合、その割当も残す。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    frame = next((item for item in _image_frames(project.content_master.root) if item.id == element_id), None)
    if frame is None:
        raise ValueError(f"画像枠が見つからない: {element_id}")
    if frame.fit_mode == FitMode.ROI:
        raise ValueError("拡大枠には素材を直接割り当てられません")
    if frame.fit_mode != FitMode.CONTAIN:
        raise ValueError("この画像枠には素材を割り当てられません")
    matches = [item for item in project.slide.bindings if item.element_id == element_id]
    if len(matches) > 1:
        raise ValueError("この枠の割当が競合しているため変更しません")
    if len(matches) == 0 or matches[0].asset_id is None:
        raise ValueError("この枠には素材が割り当てられていません")
    matches[0].asset_id = None


def assign_registered_asset(project: Project, element_id: str, asset_id: str) -> str:
    """登録済みで未割当の素材を、一つの通常表示の画像枠へ割り当てる。

    素材のパス、寸法、表示名は変えない。元ファイルも書き換えない。
    別の枠が使っている素材は共有しない。
    この枠が別の素材を指していた場合、その素材の記録は残して割当だけを切り替える。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    frame = next((item for item in _image_frames(project.content_master.root) if item.id == element_id), None)
    if frame is None:
        raise ValueError(f"画像枠が見つからない: {element_id}")
    if frame.fit_mode == FitMode.ROI:
        raise ValueError("拡大枠には素材を直接割り当てられません")
    if frame.fit_mode != FitMode.CONTAIN:
        raise ValueError("この画像枠には素材を割り当てられません")
    asset = next((item for item in project.assets if item.id == asset_id), None)
    if asset is None:
        raise ValueError("素材が見つからない")
    path = Path(asset.path)
    if not path.is_file():
        raise ValueError("画像ファイルが見つからない")
    _read_image_size(path)
    users = [item for item in project.slide.bindings if item.asset_id == asset_id]
    if any(item.element_id != element_id for item in users):
        raise ValueError("この素材は別の枠に割り当てられています")
    matches = [item for item in project.slide.bindings if item.element_id == element_id]
    if len(matches) > 1:
        raise ValueError("この枠の割当が競合しているため変更しません")
    if len(matches) == 1 and matches[0].asset_id == asset_id:
        raise ValueError("この枠にはすでにその素材が割り当てられています")
    if len(matches) == 1:
        matches[0].asset_id = asset_id
    else:
        project.slide.bindings.append(Binding(element_id=element_id, asset_id=asset_id))
    return asset_id


def share_registered_asset(project: Project, element_id: str, asset_id: str) -> str:
    """すでに別の枠が使っている素材を、選んだ通常表示の画像枠でも使う。

    素材のパス、寸法、表示名は変えない。元ファイルも書き換えない。
    ほかの枠の割当はそのまま残す。
    この枠が別の素材を指していた場合、その素材の記録は残して割当だけを切り替える。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    frame = next((item for item in _image_frames(project.content_master.root) if item.id == element_id), None)
    if frame is None:
        raise ValueError(f"画像枠が見つからない: {element_id}")
    if frame.fit_mode == FitMode.ROI:
        raise ValueError("拡大枠には素材を直接割り当てられません")
    if frame.fit_mode != FitMode.CONTAIN:
        raise ValueError("この画像枠には素材を割り当てられません")
    asset = next((item for item in project.assets if item.id == asset_id), None)
    if asset is None:
        raise ValueError("素材が見つからない")
    path = Path(asset.path)
    if not path.is_file():
        raise ValueError("画像ファイルが見つからない")
    _read_image_size(path)
    users = [item for item in project.slide.bindings if item.asset_id == asset_id]
    if not any(item.element_id != element_id for item in users):
        if any(item.element_id == element_id for item in users):
            raise ValueError("この枠にはすでにその素材が割り当てられています")
        raise ValueError("この素材はまだ枠に割り当てられていません")
    matches = [item for item in project.slide.bindings if item.element_id == element_id]
    if len(matches) > 1:
        raise ValueError("この枠の割当が競合しているため変更しません")
    if len(matches) == 1 and matches[0].asset_id == asset_id:
        raise ValueError("この枠にはすでにその素材が割り当てられています")
    if len(matches) == 1:
        matches[0].asset_id = asset_id
    else:
        project.slide.bindings.append(Binding(element_id=element_id, asset_id=asset_id))
    return asset_id


def remove_unused_asset(project: Project, asset_id: str) -> None:
    """どの枠にも割り当てられていない素材の記録だけを消す。

    元ファイルは削除しない。グループの所属は外す。枠、割当、ROI は変えない。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    index = next((item_index for item_index, item in enumerate(project.assets) if item.id == asset_id), None)
    if index is None:
        raise ValueError("素材が見つからない")
    if any(item.asset_id == asset_id for item in project.slide.bindings):
        raise ValueError("この素材は枠に割り当てられているため削除しません")
    del project.assets[index]
    for dataset in project.datasets:
        dataset.asset_ids = [item for item in dataset.asset_ids if item != asset_id]


_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".webp"}


def register_folder_images(project: Project, folder: str) -> tuple[int, int]:
    """フォルダ以下の画像を素材として追加する。

    枠への割当はしない。サブフォルダも対象にする。
    すでに同じパスの素材があるファイルは追加しない。
    画像として読めないファイルはスキップする。元ファイルは書き換えない。
    戻り値は追加した件数とスキップした件数。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    directory = Path(folder)
    if not directory.is_dir():
        raise ValueError("フォルダが見つからない")
    known: set[Path] = set()
    for asset in project.assets:
        try:
            known.add(Path(asset.path).resolve())
        except OSError:
            continue
    added = 0
    skipped = 0
    files = sorted(
        (path for path in directory.rglob("*") if path.is_file()),
        key=lambda item: item.relative_to(directory).as_posix().lower(),
    )
    for child in files:
        if child.suffix.lower() not in _IMAGE_SUFFIXES:
            skipped += 1
            continue
        try:
            resolved = child.resolve()
        except OSError:
            skipped += 1
            continue
        if resolved in known:
            continue
        try:
            width, height = _read_image_size(child)
        except ValueError:
            skipped += 1
            continue
        project.assets.append(
            Asset(
                id=_next_asset_id(project),
                path=str(resolved),
                width_px=width,
                height_px=height,
                display_name=_folder_display_name(directory, child),
            )
        )
        known.add(resolved)
        added += 1
    return added, skipped


def _folder_display_name(directory: Path, child: Path) -> str:
    relative = child.relative_to(directory)
    stem = child.stem or child.name
    if len(relative.parts) == 1:
        return stem
    parent = relative.parent.as_posix()
    return f"{parent}/{stem}"


def remove_roi(project: Project, roi_id: str) -> None:
    """指定した ROI だけを外す。ほかの ROI や素材、拡大枠の割当は変えない。"""
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    index = next((item_index for item_index, item in enumerate(project.slide.rois) if item.id == roi_id), None)
    if index is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    del project.slide.rois[index]


def zoom_link_label(zoom_ids: list[str], used: set[str]) -> str:
    """空いている拡大枠がちょうど一つのときだけ、その ID を返す。"""
    free = [item for item in zoom_ids if item not in used]
    if len(free) == 1:
        return free[0]
    if len(free) > 1:
        return "ambiguous"
    return "-"


def _read_image_size(path: Path) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            width, height = image.size
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError("画像として読めません") from exc
    if width <= 0 or height <= 0:
        raise ValueError("画像のピクセル寸法が不正")
    return width, height


def _next_asset_id(project: Project) -> str:
    used = {item.id for item in project.assets}
    number = 1
    while f"asset-{number}" in used:
        number += 1
    return f"asset-{number}"


def _next_roi_id(project: Project) -> str:
    used = {item.id for item in project.slide.rois}
    number = 1
    while f"roi-{number}" in used:
        number += 1
    return f"roi-{number}"


def _contain_frame(project: Project, element_id: str) -> ImageFrameNode:
    frame = next((item for item in _image_frames(project.content_master.root) if item.id == element_id), None)
    if frame is None or frame.fit_mode != FitMode.CONTAIN:
        raise ValueError("ROI は通常表示の画像にだけ作れます")
    return frame


def _image_frames(node: Element) -> list[ImageFrameNode]:
    if isinstance(node, ImageFrameNode):
        return [node]
    if isinstance(node, (StackNode, GridNode)):
        found: list[ImageFrameNode] = []
        for child in node.children:
            found.extend(_image_frames(child))
        return found
    return []


def _source_asset_for(project: Project, element_id: str) -> Asset:
    bindings = [item for item in project.slide.bindings if item.element_id == element_id]
    if len(bindings) != 1 or bindings[0].asset_id is None:
        raise ValueError("ROI の元画像に素材が一つ割り当てられていません")
    asset = next((item for item in project.assets if item.id == bindings[0].asset_id), None)
    if asset is None or asset.width_px <= 0 or asset.height_px <= 0:
        raise ValueError("ROI の元画像に寸法がない")
    return asset


def _source_asset(project: Project, roi: Roi) -> Asset:
    binding = next(
        (item for item in project.slide.bindings if item.element_id == roi.source_element_id),
        None,
    )
    if binding is None or binding.asset_id is None:
        raise ValueError("ROI の元画像に素材がない")
    asset = next((item for item in project.assets if item.id == binding.asset_id), None)
    if asset is None or asset.width_px <= 0 or asset.height_px <= 0:
        raise ValueError("ROI の元画像に寸法がない")
    return asset


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "session":
        from smart_report_builder.edit_session import serve

        return serve()
    if args and args[0] == "new-project":
        return _new_project(args[1:])
    if args and args[0] == "open-pptx":
        return _open_pptx_command(args[1:])
    if args and args[0] == "add-layout":
        return _add_layout_command(args[1:])
    if args and args[0] == "add-slide":
        return _add_slide_command(args[1:])
    if args and args[0] == "set-slide-layout":
        return _set_slide_layout_command(args[1:])
    if args and args[0] in {"activate-layout", "activate-slide"}:
        return _activate_layout_command(args[1:])
    if args and args[0] in {"remove-layout", "remove-slide"}:
        return _remove_layout_command(args[1:])
    if args and args[0] == "create":
        return _create(args[1:])
    if args and args[0] == "delete":
        return _delete(args[1:])
    if args and args[0] in {"link", "unlink"}:
        return _zoom(args[0], args[1:])
    if args and args[0] == "rename":
        return _rename(args[1:])
    if args and args[0] == "annotate":
        return _annotate(args[1:])
    if args and args[0] == "place-note":
        return _place_note(args[1:])
    if args and args[0] == "reset-note":
        return _reset_note(args[1:])
    if args and args[0] == "duplicate":
        return _duplicate(args[1:])
    if args and args[0] == "assign":
        return _assign(args[1:])
    if args and args[0] == "unassign":
        return _unassign(args[1:])
    if args and args[0] == "assign-asset":
        return _assign_asset(args[1:])
    if args and args[0] == "share-asset":
        return _share_asset(args[1:])
    if args and args[0] == "remove-asset":
        return _remove_asset(args[1:])
    if args and args[0] == "register-folder":
        return _register_folder(args[1:])
    if args and args[0] == "register-ordered":
        return _register_ordered(args[1:])
    if args and args[0] == "set-assignment-rule":
        return _set_assignment_rule(args[1:])
    if args and args[0] == "expand-assignment":
        return _expand_assignment(args[1:])
    if args and args[0] == "propose-ordered":
        return _propose_ordered(args[1:])
    if args and args[0] == "accept-ordered":
        return _accept_ordered(args[1:])
    if args and args[0] == "suggest":
        return _suggest(args[1:])
    if args and args[0] == "apply-suggestion":
        return _apply_suggestion(args[1:])
    if args and args[0] == "accept-ready":
        return _accept_ready(args[1:])
    if args and args[0] == "variants":
        return _variants(args[1:])
    if args and args[0] == "apply-variant":
        return _apply_variant_command(args[1:])
    if args and args[0] == "master-roi":
        return _master_roi_command(args[1:])
    if args and args[0] == "apply-master":
        return _apply_master_command(args[1:])
    if args and args[0] == "update-master":
        return _update_master_command(args[1:])
    if args and args[0] == "add-table":
        return _add_table_command(args[1:])
    if args and args[0] == "add-table-row":
        return _add_table_row_command(args[1:])
    if args and args[0] == "add-table-column":
        return _add_table_column_command(args[1:])
    if args and args[0] == "arrange-zooms":
        return _arrange_zooms_command(args[1:])
    if args and args[0] == "resize-frame":
        return _resize_frame_command(args[1:])
    if args and args[0] == "add-frame":
        return _add_frame_command(args[1:])
    if args and args[0] == "remove-frame":
        return _remove_frame_command(args[1:])
    if args and args[0] == "set-frame-kind":
        return _set_frame_kind_command(args[1:])
    if args and args[0] == "create-dataset":
        return _create_dataset_command(args[1:])
    if args and args[0] == "add-dataset-asset":
        return _add_dataset_asset_command(args[1:])
    if args and args[0] == "remove-dataset-asset":
        return _remove_dataset_asset_command(args[1:])
    if args and args[0] == "set-table-cell":
        return _set_table_cell_command(args[1:])
    if args and args[0] == "set-page-title":
        return _set_page_title_command(args[1:])
    if args and args[0] == "set-finding":
        return _set_finding_command(args[1:])
    if args and args[0] == "export-pptx":
        return _export_pptx(args[1:])
    if args and args[0] == "undo":
        return _undo(args[1:])
    if args and args[0] == "redo":
        return _redo(args[1:])
    return _update(args)


def _new_project(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Create a project with image frames and a caption")
    parser.add_argument("directory")
    parser.add_argument("--images", type=int, default=2)
    parser.add_argument("--arrangement", default="horizontal")
    parser.add_argument("--template", default="images")
    parser.add_argument("--paper", default="16x9")
    args = parser.parse_args(argv)
    try:
        project = create_report(
            image_count=args.images,
            arrangement=args.arrangement,
            template=args.template,
            paper=args.paper,
        )
        project_path, layout_path, result = _write_new_project(Path(args.directory), project)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"created {project_path} {layout_path} {result.preview_mode}")
    return 0


def open_pptx_preview(pptx_path: Path, directory: Path) -> Path:
    """PPTX の撮像スライドを、元ファイルを変えずにプレビュー用プロジェクトにする。"""
    source = pptx_path.resolve()
    if not source.is_file():
        raise ValueError("PPTX が見つからない")
    directory.mkdir(parents=True, exist_ok=True)
    layout_path = directory / "layout.json"
    project_path = directory / "project.json"
    if layout_path.is_file() and project_path.is_file():
        return layout_path
    spec = read_imaging_template(source)
    paper = "portrait" if spec.slide_height_pt > spec.slide_width_pt else "landscape"
    project = create_report(paper=paper)
    template_copy = directory / "template.pptx"
    shutil.copyfile(source, template_copy)
    chrome = directory / "chrome.png"
    render_chrome(spec, chrome)
    design = project.design_master
    design.slide_width_pt = spec.slide_width_pt
    design.slide_height_pt = spec.slide_height_pt
    design.orientation = paper
    design.body = spec.body
    design.title_frame = spec.title_frame
    design.title_shape_name = spec.title_shape_name
    design.title_font = spec.title_font
    design.title_font_pt = spec.title_font_pt
    design.title_color = spec.title_color
    design.page_title = DEFAULT_PAGE_TITLE
    design.template_path = str(template_copy.resolve())
    design.chrome_image = str(chrome.resolve())
    names = imaging_slide_names_at(source)
    if len(names) > 1:
        _ensure_deck(project)
        project.report_slides[0].name = names[0]
        for name in names[1:]:
            add_slide(project, layout_id=project.layouts[0].id, name=name, activate=False)
        _activate_slide(project, project.report_slides[0].id)
    result = layout_slide(project)
    save_project(project, project_path)
    save_layout_result(result, layout_path)
    write_pptx_slides(layouts_for_pptx(project, result), directory / "report.pptx")
    return layout_path


def _open_pptx_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Preview an imaging slide from a PPTX without editing it")
    parser.add_argument("pptx")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        layout_path = open_pptx_preview(Path(args.pptx), Path(args.out))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"opened {layout_path}")
    return 0


def _write_new_project(directory: Path, project: Project):
    directory.mkdir(parents=True, exist_ok=True)
    project_path = directory / "project.json"
    layout_path = directory / "layout.json"
    pptx_path = directory / "report.pptx"
    if any(path.exists() for path in (project_path, layout_path, pptx_path)):
        raise ValueError("すでにファイルがあるため、新しいプロジェクトは作りません")
    materialize_template(project, directory)
    result = layout_slide(project)
    save_project(project, project_path)
    save_layout_result(result, layout_path)
    _announce_layout(layout_path)
    _publish_pptx(result, pptx_path, layout_path, project_path=project_path)
    return project_path, layout_path, result


def add_layout(
    project: Project,
    *,
    image_count: int = 2,
    arrangement: str = "horizontal",
    template: str = "images",
) -> str:
    """新しいレイアウトを作り、それを使うスライドを1枚足す。"""
    _ensure_deck(project)
    fresh = create_report(image_count=image_count, arrangement=arrangement, template=template)
    layout_id = _next_numbered_id("layout-", {item.id for item in project.layouts})
    fresh.content_master.id = f"{fresh.content_master.id}-{layout_id}"
    fresh.content_master.design_master_id = project.design_master.id
    layout = LayoutDefinition(
        id=layout_id,
        name=_unique_label([item.name for item in project.layouts], fresh.content_master.name),
        content_master=fresh.content_master,
    )
    project.layouts.append(layout)
    slide_id = _append_slide(project, layout)
    _activate_slide(project, slide_id)
    return slide_id


def add_slide(
    project: Project,
    layout_id: str | None = None,
    name: str | None = None,
    *,
    activate: bool = True,
) -> str:
    """今あるレイアウトを使うスライドを足す。配置の枠は共有し、画像と ROI は空にする。"""
    _ensure_deck(project)
    chosen = layout_id or _active_slide(project).layout_id
    layout = _layout_by_id(project, chosen)
    slide_id = _append_slide(project, layout, name=name)
    if activate:
        _activate_slide(project, slide_id)
    return slide_id


def set_slide_layout(project: Project, slide_id: str, layout_id: str) -> str:
    """スライドが使うレイアウトを付け替える。枠に無い画像割当と ROI は外す。"""
    _ensure_deck(project)
    item = _slide_by_id(project, slide_id)
    layout = _layout_by_id(project, layout_id)
    if item.layout_id == layout.id:
        return slide_id
    item.layout_id = layout.id
    item.slide.content_master_id = layout.content_master.id
    _drop_missing_slide_content(item.slide, layout.content_master)
    if project.active_slide_id == item.id:
        project.content_master = layout.content_master
        project.slide = item.slide
    return slide_id


def activate_page(project: Project, slide_id: str) -> str:
    if not project.report_slides:
        raise ValueError("切り替えるスライドがありません")
    _activate_slide(project, slide_id)
    return slide_id


def remove_layout(project: Project, slide_id: str) -> str:
    """スライドを報告から外す。最後の1枚は残す。使われなくなったレイアウトも外す。"""
    if len(project.report_slides) <= 1:
        raise ValueError("最後のスライドは削除できません")
    index = next((i for i, item in enumerate(project.report_slides) if item.id == slide_id), None)
    if index is None:
        raise ValueError("スライドが見つからない")
    project.report_slides.pop(index)
    used = {item.layout_id for item in project.report_slides}
    project.layouts = [item for item in project.layouts if item.id in used]
    if project.active_slide_id not in {item.id for item in project.report_slides}:
        neighbor = project.report_slides[min(index, len(project.report_slides) - 1)]
        _activate_slide(project, neighbor.id)
    if len(project.report_slides) == 1 and len(project.layouts) == 1:
        only = project.report_slides[0]
        layout = project.layouts[0]
        project.content_master = layout.content_master
        project.slide = only.slide
        project.report_slides = []
        project.layouts = []
        project.active_slide_id = None
    return slide_id


def _ensure_deck(project: Project) -> None:
    if project.report_slides:
        return
    project.layouts = [
        LayoutDefinition(
            id="layout-1",
            name=project.content_master.name,
            content_master=project.content_master,
        )
    ]
    project.report_slides = [
        ReportSlide(
            id="slide-1",
            name="スライド1",
            layout_id="layout-1",
            slide=project.slide,
        )
    ]
    project.active_slide_id = "slide-1"


def _append_slide(project: Project, layout: LayoutDefinition, name: str | None = None) -> str:
    slide_id = _next_numbered_id("slide-", {item.id for item in project.report_slides})
    number = slide_id.removeprefix("slide-")
    label = _unique_label([item.name for item in project.report_slides], name or f"スライド{number}")
    title = ""
    if project.design_master.orientation:
        title = project.design_master.page_title or DEFAULT_PAGE_TITLE
    instance = SlideInstance(
        id=slide_id,
        content_master_id=layout.content_master.id,
        title=title,
    )
    project.report_slides.append(
        ReportSlide(id=slide_id, name=label, layout_id=layout.id, slide=instance)
    )
    return slide_id


def _activate_slide(project: Project, slide_id: str) -> None:
    item = _slide_by_id(project, slide_id)
    layout = _layout_by_id(project, item.layout_id)
    project.active_slide_id = item.id
    project.content_master = layout.content_master
    project.slide = item.slide


def _active_slide(project: Project) -> ReportSlide:
    return _slide_by_id(project, project.active_slide_id or "")


def _slide_by_id(project: Project, slide_id: str) -> ReportSlide:
    item = next((slide for slide in project.report_slides if slide.id == slide_id), None)
    if item is None:
        raise ValueError("スライドが見つからない")
    return item


def _layout_by_id(project: Project, layout_id: str) -> LayoutDefinition:
    item = next((layout for layout in project.layouts if layout.id == layout_id), None)
    if item is None:
        raise ValueError("レイアウトが見つからない")
    return item


def _unique_label(used_names: list[str], name: str) -> str:
    used = set(used_names)
    if name not in used:
        return name
    number = 2
    while f"{name} {number}" in used:
        number += 1
    return f"{name} {number}"


def _drop_missing_slide_content(slide: SlideInstance, content: object) -> None:
    ids = _tree_ids(content)
    slide.bindings = [item for item in slide.bindings if item.element_id in ids]
    kept = []
    for roi in slide.rois:
        if roi.source_element_id not in ids:
            continue
        if roi.zoom_element_id is not None and roi.zoom_element_id not in ids:
            roi.zoom_element_id = None
        kept.append(roi)
    slide.rois = kept


def _tree_ids(node: object) -> set[str]:
    found = set()
    node_id = getattr(node, "id", None)
    if isinstance(node_id, str):
        found.add(node_id)
    for child in getattr(node, "children", []) or []:
        found.update(_tree_ids(child))
    return found


def layouts_for_pptx(project: Project, active: object) -> list:
    if len(project.report_slides) <= 1:
        return [active]
    results = []
    for item in project.report_slides:
        if item.id == project.active_slide_id:
            results.append(active)
            continue
        layout = _layout_by_id(project, item.layout_id)
        results.append(
            layout_slide(
                Project(
                    design_master=project.design_master,
                    content_master=layout.content_master,
                    assets=project.assets,
                    slide=item.slide,
                    datasets=project.datasets,
                    schema_version=project.schema_version,
                )
            )
        )
    return results


def _add_layout_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Add a layout to the current project without a new JSON file")
    parser.add_argument("project")
    parser.add_argument("--images", type=int, default=2)
    parser.add_argument("--arrangement", default="horizontal")
    parser.add_argument("--template", default="images")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        page_id = add_layout(
            project,
            image_count=args.images,
            arrangement=args.arrangement,
            template=args.template,
        )
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"slide {page_id}")
    return 0


def _add_slide_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Add a slide that reuses a layout")
    parser.add_argument("project")
    parser.add_argument("--layout-id")
    parser.add_argument("--name")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        slide_id = add_slide(project, layout_id=args.layout_id, name=args.name)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"slide {slide_id}")
    return 0


def _set_slide_layout_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Choose which layout one slide uses")
    parser.add_argument("project")
    parser.add_argument("slide_id")
    parser.add_argument("layout_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        slide_id = set_slide_layout(project, args.slide_id, args.layout_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"slide {slide_id}")
    return 0


def _activate_layout_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Show another layout from the same project")
    parser.add_argument("project")
    parser.add_argument("page_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        page_id = activate_page(project, args.page_id)
        _save_outputs(project, args.project, args.layout, args.pptx, record_undo=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"active {page_id}")
    return 0


def _remove_layout_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Remove one layout from the current project")
    parser.add_argument("project")
    parser.add_argument("page_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        page_id = remove_layout(project, args.page_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"removed {page_id}")
    return 0


def _create(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Add one ROI and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("source_element_id")
    parser.add_argument("x", type=float)
    parser.add_argument("y", type=float)
    parser.add_argument("width", type=float)
    parser.add_argument("height", type=float)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        roi_id, zoom_label = add_normalized_roi(
            project,
            args.source_element_id,
            args.x,
            args.y,
            args.width,
            args.height,
        )
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"created {roi_id}")
    print(f"zoom {zoom_label}")
    return 0


def _zoom(command: str, argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Link or unlink one ROI and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--zoom")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        zoom_label, replaced = set_roi_zoom(
            project,
            args.roi_id,
            linked=command == "link",
            zoom_element_id=args.zoom,
        )
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"zoom {zoom_label}")
    print(f"replaced {replaced or '-'}")
    return 0


def _rename(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Rename one ROI and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--name", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        cleaned = rename_roi(project, args.roi_id, args.name)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"renamed {args.roi_id} {cleaned}")
    return 0


def _annotate(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Set one ROI note and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--text", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        cleaned = set_roi_note(project, args.roi_id, args.text)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"noted {args.roi_id} {cleaned}")
    return 0


def _place_note(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Move one ROI note and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("x", type=float)
    parser.add_argument("y", type=float)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        dx, dy = set_note_position(project, args.roi_id, args.x, args.y)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"placed {args.roi_id} {dx} {dy}")
    return 0


def _reset_note(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Return one ROI note to its automatic position")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        clear_note_position(project, args.roi_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"reset {args.roi_id}")
    return 0


def _assign(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Assign an image file to one contain frame")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("image")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        asset_id = assign_frame_image(project, args.element_id, args.image)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"assigned {args.element_id} {asset_id}")
    return 0


def _unassign(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Clear the image assigned to one contain frame")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        clear_frame_image(project, args.element_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"unassigned {args.element_id}")
    return 0


def _assign_asset(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Assign one registered asset to a contain frame")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("asset_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        asset_id = assign_registered_asset(project, args.element_id, args.asset_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"assigned {args.element_id} {asset_id}")
    return 0


def _share_asset(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Use one assigned asset on another contain frame")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("asset_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        asset_id = share_registered_asset(project, args.element_id, args.asset_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"shared {args.element_id} {asset_id}")
    return 0


def _remove_asset(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Remove one unused asset record and keep the file")
    parser.add_argument("project")
    parser.add_argument("asset_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        remove_unused_asset(project, args.asset_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"removed {args.asset_id}")
    return 0


def _register_folder(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Register images from one folder without assigning them")
    parser.add_argument("project")
    parser.add_argument("folder")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        added, skipped = register_folder_images(project, args.folder)
        if added:
            _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"registered {added} skipped {skipped}")
    return 0


def _duplicate(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Duplicate one ROI and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        new_id, shifted = duplicate_roi(project, args.roi_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"duplicated {new_id}")
    print("shift yes" if shifted else "shift no")
    return 0


def _delete(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Remove one ROI and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        remove_roi(project, args.roi_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"deleted {args.roi_id}")
    return 0


def _undo(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Undo the last ROI edit and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = restore_last_roi_edit(args.project)
        _publish_restored(project, args.layout, args.pptx, project_path=args.project)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("undone")
    return 0


def _redo(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Redo the last undone ROI edit and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = restore_redone_roi_edit(args.project)
        _publish_restored(project, args.layout, args.pptx, project_path=args.project)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("redone")
    return 0


def _update(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Update one ROI and rebuild the layout")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("x", type=float)
    parser.add_argument("y", type=float)
    parser.add_argument("width", type=float)
    parser.add_argument("height", type=float)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)

    try:
        project = load_project(args.project)
        apply_normalized_roi(project, args.roi_id, args.x, args.y, args.width, args.height)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"updated {args.roi_id}")
    return 0


def undo_snapshot_path(project_path: str | Path) -> Path:
    """直前の ROI 操作のプロジェクトを置くパス。配置結果とは別ファイル。"""
    destination = Path(project_path)
    return destination.with_name(f"{destination.name}.undo")


def redo_snapshot_path(project_path: str | Path) -> Path:
    """元に戻す直前のプロジェクトを置くパス。配置結果とは別ファイル。"""
    destination = Path(project_path)
    return destination.with_name(f"{destination.name}.redo")


def restore_last_roi_edit(project_path: str | Path) -> Project:
    """直前の操作の前へ戻す。戻す前の内容はやり直し用に残す。"""
    destination = Path(project_path)
    history = _load_history(destination)
    if not history["undo"]:
        raise ValueError("戻せる ROI 操作がありません")
    current = destination.read_bytes() if destination.is_file() else b""
    previous = _decode(history["undo"].pop())
    load_project_bytes = previous
    _validate_project_bytes(load_project_bytes)
    history["redo"].append(_encode(current))
    history["redo"] = history["redo"][-_HISTORY_LIMIT:]
    _write_bytes(destination, previous)
    _store_history(destination, history)
    _mirror_history(destination, history)
    return load_project(destination)


def restore_redone_roi_edit(project_path: str | Path) -> Project:
    """元に戻した操作をやり直す。やり直す前の内容は、もう一度戻せるように残す。"""
    destination = Path(project_path)
    history = _load_history(destination)
    if not history["redo"]:
        raise ValueError("やり直せる ROI 操作がありません")
    current = destination.read_bytes() if destination.is_file() else b""
    nxt = _decode(history["redo"].pop())
    _validate_project_bytes(nxt)
    history["undo"].append(_encode(current))
    history["undo"] = history["undo"][-_HISTORY_LIMIT:]
    _write_bytes(destination, nxt)
    _store_history(destination, history)
    _mirror_history(destination, history)
    return load_project(destination)


def _swap_in_snapshot(destination: Path, snapshot: Path, keep_current: Path) -> Project:
    load_project(snapshot)
    if destination.is_file():
        _copy_bytes(destination, keep_current)
    temporary = destination.with_name(f"{destination.name}.restore.tmp")
    temporary.write_bytes(snapshot.read_bytes())
    try:
        os.replace(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return load_project(destination)


def _publish_restored(
    project: Project,
    layout_path: str | None,
    pptx_path: str | None,
    project_path: str | None = None,
) -> None:
    result = layout_slide(project)
    if layout_path:
        save_layout_result(result, layout_path)
        _announce_layout(layout_path)
    if pptx_path:
        _publish_pptx(result, pptx_path, layout_path, project_path=project_path, project=project)


def _save_outputs(
    project: Project,
    project_path: str,
    layout_path: str | None,
    pptx_path: str | None,
    *,
    record_undo: bool = True,
) -> None:
    destination = Path(project_path)
    recorded = record_undo and destination.is_file()
    if recorded:
        _push_history(destination)
    save_project(project, destination)
    result = layout_slide(project)
    if layout_path:
        save_layout_result(result, layout_path)
        _announce_layout(layout_path)
    if pptx_path:
        _publish_pptx(result, pptx_path, layout_path, project_path=project_path, project=project)


def _announce_layout(layout_path: str | Path) -> None:
    """配置 JSON を書き終えたことを、PPTX より先に知らせる。"""
    if not os.environ.get("SMART_REPORT_LAYOUT_NOTIFY"):
        return
    print(f"LAYOUT_READY\t{layout_path}", flush=True)


def _publish_pptx(
    result,
    pptx_path: str | Path,
    layout_path: str | Path | None,
    project_path: str | Path | None = None,
    project: Project | None = None,
) -> None:
    if layout_path and os.environ.get("SMART_REPORT_LAYOUT_NOTIFY"):
        _spawn_pptx_export(layout_path, pptx_path, project_path)
        return
    slides = layouts_for_pptx(project, result) if project is not None else [result]
    write_pptx_slides(slides, pptx_path, prior_path=pptx_path)


def _spawn_pptx_export(
    layout_path: str | Path,
    pptx_path: str | Path,
    project_path: str | Path | None = None,
) -> None:
    seq = _claim_pptx_seq(Path(pptx_path))
    flags = 0
    if sys.platform == "win32":
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    command = [
        sys.executable,
        "-m",
        "smart_report_builder.roi_edit",
        "export-pptx",
        str(layout_path),
        str(pptx_path),
        str(seq),
    ]
    if project_path:
        command.extend(["--project", str(project_path)])
    subprocess.Popen(
        command,
        creationflags=flags,
        close_fds=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _claim_pptx_seq(pptx_path: Path) -> int:
    seq_path = _pptx_seq_path(pptx_path)

    def claim() -> int:
        current = _read_pptx_seq(seq_path)
        seq = current + 1
        seq_path.write_text(f"{seq}\n", encoding="utf-8")
        return seq

    return _with_pptx_seq_lock(pptx_path, claim)


def pptx_seq_is_current(pptx_path: Path, seq: int) -> bool:
    return _with_pptx_seq_lock(
        pptx_path,
        lambda: _read_pptx_seq(_pptx_seq_path(pptx_path)) == seq,
    )


def _export_slides(layout_path: str, project_path: str | None) -> list:
    if project_path:
        project = load_project(project_path)
        if len(project.report_slides) > 1:
            return layouts_for_pptx(project, layout_slide(project))
    return [load_layout_result(layout_path)]


def _export_pptx(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Write a PPTX unless a newer save exists")
    parser.add_argument("layout")
    parser.add_argument("pptx")
    parser.add_argument("seq", type=int)
    parser.add_argument("--project")
    args = parser.parse_args(argv)
    pptx_path = Path(args.pptx)
    if not pptx_seq_is_current(pptx_path, args.seq):
        return 0
    try:
        slides = _export_slides(args.layout, args.project)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    temporary = pptx_path.with_name(f"{pptx_path.name}.{args.seq}.partial")
    try:
        write_pptx_slides(slides, temporary, prior_path=pptx_path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise

    def publish() -> bool:
        if _read_pptx_seq(_pptx_seq_path(pptx_path)) != args.seq:
            temporary.unlink(missing_ok=True)
            return False
        os.replace(temporary, pptx_path)
        return True

    _with_pptx_seq_lock(pptx_path, publish)
    return 0


def _with_pptx_seq_lock(pptx_path: Path, action):
    seq_path = _pptx_seq_path(pptx_path)
    seq_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = Path(f"{seq_path}.lock")
    with lock_path.open("a+b") as lock:
        locked = False
        try:
            _lock_file(lock)
            locked = True
            return action()
        finally:
            if locked:
                _unlock_file(lock)


def _pptx_seq_path(pptx_path: Path) -> Path:
    return Path(f"{pptx_path}.seq")


def _read_pptx_seq(seq_path: Path) -> int:
    if not seq_path.is_file():
        return 0
    try:
        return int(seq_path.read_text(encoding="utf-8").strip() or "0")
    except ValueError:
        return 0


def _lock_file(lock) -> None:
    if sys.platform == "win32":
        import msvcrt

        lock.seek(0)
        lock.write(b"\0")
        lock.flush()
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
        return
    import fcntl

    fcntl.flock(lock, fcntl.LOCK_EX)


def _unlock_file(lock) -> None:
    if sys.platform == "win32":
        import msvcrt

        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        return
    import fcntl

    fcntl.flock(lock, fcntl.LOCK_UN)


def _push_history(project_path: Path) -> None:
    history = _load_history(project_path)
    history["undo"].append(_encode(project_path.read_bytes()))
    history["undo"] = history["undo"][-_HISTORY_LIMIT:]
    history["redo"] = []
    _store_history(project_path, history)
    _mirror_history(project_path, history)


def _load_history(project_path: Path) -> dict[str, list[str]]:
    path = _history_path(project_path)
    if path.is_file():
        payload = json.loads(path.read_text(encoding="utf-8"))
        return {
            "undo": [str(item) for item in payload.get("undo", [])],
            "redo": [str(item) for item in payload.get("redo", [])],
        }
    history: dict[str, list[str]] = {"undo": [], "redo": []}
    undo = undo_snapshot_path(project_path)
    redo = redo_snapshot_path(project_path)
    if undo.is_file():
        history["undo"].append(_encode(undo.read_bytes()))
    if redo.is_file():
        history["redo"].append(_encode(redo.read_bytes()))
    return history


def _store_history(project_path: Path, history: dict[str, list[str]]) -> None:
    _write_bytes(
        _history_path(project_path),
        json.dumps(history, ensure_ascii=False).encode("utf-8"),
    )


def _mirror_history(project_path: Path, history: dict[str, list[str]]) -> None:
    if history["undo"]:
        _write_bytes(undo_snapshot_path(project_path), _decode(history["undo"][-1]))
    else:
        undo_snapshot_path(project_path).unlink(missing_ok=True)
    if history["redo"]:
        _write_bytes(redo_snapshot_path(project_path), _decode(history["redo"][-1]))
    else:
        redo_snapshot_path(project_path).unlink(missing_ok=True)


def _history_path(project_path: Path) -> Path:
    return project_path.with_name(f"{project_path.name}.history.json")


def _encode(payload: bytes) -> str:
    return base64.b64encode(payload).decode("ascii")


def _decode(payload: str) -> bytes:
    return base64.b64decode(payload.encode("ascii"))


def _validate_project_bytes(payload: bytes) -> None:
    from smart_report_builder.models import project_from_dict

    project_from_dict(json.loads(payload.decode("utf-8")))


def _write_bytes(destination: Path, payload: bytes) -> None:
    temporary = destination.with_name(f"{destination.name}.tmp")
    temporary.write_bytes(payload)
    try:
        os.replace(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _copy_bytes(source: Path, destination: Path) -> None:
    temporary = destination.with_name(f"{destination.name}.tmp")
    temporary.write_bytes(source.read_bytes())
    try:
        os.replace(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _register_ordered(argv: list[str]) -> int:
    from smart_report_builder.ordered_assignment import register_ordered_assets

    parser = argparse.ArgumentParser(description="Register ordered images without assigning frames")
    parser.add_argument("project")
    parser.add_argument("--payload", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        records = json.loads(args.payload)
        if not isinstance(records, list):
            raise ValueError("素材の一覧が配列ではない")
        project = load_project(args.project)
        _added, _updated, ids = register_ordered_assets(project, records)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except (ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for asset_id in ids:
        print(f"asset {asset_id}")
    return 0


def _set_assignment_rule(argv: list[str]) -> int:
    from smart_report_builder.ordered_assignment import rule_from_payload, set_assignment_rule

    parser = argparse.ArgumentParser(description="Save an assignment rule on the current master")
    parser.add_argument("project")
    parser.add_argument("--payload", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        set_assignment_rule(project, rule_from_payload(json.loads(args.payload)))
        _save_outputs(project, args.project, args.layout, args.pptx)
    except (ValueError, json.JSONDecodeError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("rule")
    return 0


def _expand_assignment(argv: list[str]) -> int:
    from smart_report_builder.ordered_assignment import expand_assignment, proposal_json, rule_from_payload

    parser = argparse.ArgumentParser(description="Save a frame rule and return slide candidates")
    parser.add_argument("project")
    parser.add_argument("--payload", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        proposal = expand_assignment(project, rule_from_payload(json.loads(args.payload)))
        _save_outputs(project, args.project, args.layout, args.pptx)
    except (ValueError, json.JSONDecodeError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(proposal_json(proposal))
    return 0


def _propose_ordered(argv: list[str]) -> int:
    from smart_report_builder.ordered_assignment import propose_ordered_assignment, proposal_json

    parser = argparse.ArgumentParser(description="Propose ordered assignments without saving")
    parser.add_argument("project")
    parser.add_argument("--group", default="")
    parser.add_argument("--task", default="")
    parser.add_argument("--list-name", default="")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        proposal = propose_ordered_assignment(
            project,
            group=args.group,
            task=args.task,
            list_name=args.list_name,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(proposal_json(proposal))
    return 0


def _accept_ordered(argv: list[str]) -> int:
    from smart_report_builder.ordered_assignment import accept_ordered_assignment

    parser = argparse.ArgumentParser(description="Accept ordered assignment candidates")
    parser.add_argument("project")
    parser.add_argument("--group", default="")
    parser.add_argument("--task", default="")
    parser.add_argument("--list-name", default="")
    parser.add_argument("--ordinal", type=int)
    parser.add_argument("--frame", type=int)
    parser.add_argument("--create-slides", default="yes")
    parser.add_argument("--overwrite-labels", default="no")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        applied = accept_ordered_assignment(
            project,
            group=args.group,
            task=args.task,
            list_name=args.list_name,
            slide_ordinal=args.ordinal,
            frame_index=args.frame,
            create_slides=args.create_slides != "no",
            overwrite_labels=args.overwrite_labels == "yes",
        )
        if applied or args.ordinal is None:
            _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if not applied:
        print("none")
        return 0
    for element_id, asset_id in applied:
        print(f"assigned {element_id} {asset_id}")
    return 0


def _suggest(argv: list[str]) -> int:
    from smart_report_builder.practical import assignment_candidates, candidate_line

    parser = argparse.ArgumentParser(description="List assignment candidates without saving")
    parser.add_argument("project")
    parser.add_argument("--synonyms")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        found = assignment_candidates(project, _load_synonyms(args.synonyms))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if not found:
        print("none")
        return 0
    for item in found:
        print(candidate_line(item))
    return 0


def _apply_suggestion(argv: list[str]) -> int:
    from smart_report_builder.practical import apply_assignment_candidate

    parser = argparse.ArgumentParser(description="Apply one assignment candidate")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("asset_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    parser.add_argument("--synonyms")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        apply_assignment_candidate(
            project,
            args.element_id,
            args.asset_id,
            _load_synonyms(args.synonyms),
        )
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"assigned {args.element_id} {args.asset_id}")
    return 0


def _accept_ready(argv: list[str]) -> int:
    from smart_report_builder.practical import apply_ready_candidates

    parser = argparse.ArgumentParser(description="Assign every ready candidate and leave the rest")
    parser.add_argument("project")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    parser.add_argument("--synonyms")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        applied = apply_ready_candidates(project, _load_synonyms(args.synonyms))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if not applied:
        print("none")
        return 0
    try:
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for element_id, asset_id in applied:
        print(f"assigned {element_id} {asset_id}")
    return 0


def _load_synonyms(path: str | None) -> dict[str, list[str]] | None:
    if not path:
        return None
    source = Path(path)
    if not source.is_file():
        raise ValueError("同義語ファイルが見つからない")
    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError("同義語ファイルを読めない") from exc
    if not isinstance(payload, dict):
        raise ValueError("同義語ファイルがオブジェクトではない")
    table: dict[str, list[str]] = {}
    for role_id, words in payload.items():
        if not isinstance(words, list) or not all(isinstance(word, str) for word in words):
            raise ValueError("同義語は役割ごとの文字列配列です")
        table[str(role_id)] = list(words)
    return table


def _variants(argv: list[str]) -> int:
    from smart_report_builder.practical import propose_variants

    parser = argparse.ArgumentParser(description="List layout variants without saving")
    parser.add_argument("project")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        found = propose_variants(project)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    for item in found:
        marker = "selected" if item.selected else "open"
        print(f"{item.variant_id}\t{marker}\t{item.name}\t{item.reason}")
    return 0


def _apply_variant_command(argv: list[str]) -> int:
    from smart_report_builder.practical import apply_variant

    parser = argparse.ArgumentParser(description="Apply one layout variant")
    parser.add_argument("project")
    parser.add_argument("variant_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        apply_variant(project, args.variant_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"applied {args.variant_id}")
    return 0


def _master_roi_command(argv: list[str]) -> int:
    from smart_report_builder.practical import capture_master_roi

    parser = argparse.ArgumentParser(description="Capture one ROI as a master ROI")
    parser.add_argument("project")
    parser.add_argument("roi_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        master_id = capture_master_roi(project, args.roi_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"master {master_id}")
    return 0


def _apply_master_command(argv: list[str]) -> int:
    from smart_report_builder.practical import apply_master_roi

    parser = argparse.ArgumentParser(description="Apply a master ROI to image frames")
    parser.add_argument("project")
    parser.add_argument("master_id")
    parser.add_argument("element_ids", nargs="+")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        applied, skipped = apply_master_roi(project, args.master_id, args.element_ids)
        if applied == 0:
            raise ValueError("展開できる枠がありません")
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"applied {applied} skipped {skipped}")
    return 0


def _update_master_command(argv: list[str]) -> int:
    from smart_report_builder.practical import update_master_roi

    parser = argparse.ArgumentParser(description="Update a master ROI")
    parser.add_argument("project")
    parser.add_argument("master_id")
    parser.add_argument("x", type=float)
    parser.add_argument("y", type=float)
    parser.add_argument("width", type=float)
    parser.add_argument("height", type=float)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        update_master_roi(project, args.master_id, args.x, args.y, args.width, args.height)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"updated {args.master_id}")
    return 0


def _add_table_command(argv: list[str]) -> int:
    from smart_report_builder.practical import add_measurement_table

    parser = argparse.ArgumentParser(description="Add one measurement table")
    parser.add_argument("project")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        table_id = add_measurement_table(project)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"table {table_id}")
    return 0


def _add_table_row_command(argv: list[str]) -> int:
    from smart_report_builder.practical import add_table_row

    parser = argparse.ArgumentParser(description="Add one empty table row without changing existing cells")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        row_index = add_table_row(project, args.element_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"row {args.element_id} {row_index}")
    return 0


def _add_table_column_command(argv: list[str]) -> int:
    from smart_report_builder.practical import add_table_column

    parser = argparse.ArgumentParser(description="Add one empty table column without changing existing cells")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        column_index = add_table_column(project, args.element_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"column {args.element_id} {column_index}")
    return 0


def _resize_frame_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Resize one image frame inside its row")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("x", type=float)
    parser.add_argument("y", type=float)
    parser.add_argument("width", type=float)
    parser.add_argument("height", type=float)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        frame_id = set_image_frame_rect(
            project,
            args.element_id,
            args.x,
            args.y,
            args.width,
            args.height,
        )
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"resized {frame_id}")
    return 0


def _arrange_zooms_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Arrange one enlarged image for each ROI")
    parser.add_argument("project")
    parser.add_argument("--arrangement", default="horizontal")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        frame_ids = arrange_roi_zooms(project, args.arrangement)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"arranged {len(frame_ids)}")
    return 0


def _add_frame_command(argv: list[str]) -> int:
    from smart_report_builder.practical import add_image_frame

    parser = argparse.ArgumentParser(description="Add one unassigned contain image frame")
    parser.add_argument("project")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        frame_id = add_image_frame(project)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"frame {frame_id}")
    return 0


def _remove_frame_command(argv: list[str]) -> int:
    from smart_report_builder.practical import remove_image_frame

    parser = argparse.ArgumentParser(description="Remove one contain image frame and keep the asset file")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        frame_id = remove_image_frame(project, args.element_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"removed {frame_id}")
    return 0


def _set_frame_kind_command(argv: list[str]) -> int:
    from smart_report_builder.practical import set_image_frame_kind

    parser = argparse.ArgumentParser(description="Change the kind of one selected image frame")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("--kind", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        frame_id = set_image_frame_kind(project, args.element_id, args.kind)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"kind {frame_id} {args.kind}")
    return 0


def _create_dataset_command(argv: list[str]) -> int:
    from smart_report_builder.practical import create_dataset

    parser = argparse.ArgumentParser(description="Group assets without assigning them to frames")
    parser.add_argument("project")
    parser.add_argument("--name", required=True)
    parser.add_argument("asset_ids", nargs="+")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        dataset_id = create_dataset(project, args.name, args.asset_ids)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"dataset {dataset_id}")
    return 0


def _add_dataset_asset_command(argv: list[str]) -> int:
    from smart_report_builder.practical import add_dataset_asset

    parser = argparse.ArgumentParser(description="Add one asset to a dataset without assigning a frame")
    parser.add_argument("project")
    parser.add_argument("dataset_id")
    parser.add_argument("asset_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        add_dataset_asset(project, args.dataset_id, args.asset_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"added {args.dataset_id} {args.asset_id}")
    return 0


def _remove_dataset_asset_command(argv: list[str]) -> int:
    from smart_report_builder.practical import remove_dataset_asset

    parser = argparse.ArgumentParser(description="Remove one asset from a dataset and keep the asset record")
    parser.add_argument("project")
    parser.add_argument("dataset_id")
    parser.add_argument("asset_id")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        remove_dataset_asset(project, args.dataset_id, args.asset_id)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"detached {args.dataset_id} {args.asset_id}")
    return 0


def _set_finding_command(argv: list[str]) -> int:
    from smart_report_builder.practical import set_slide_finding

    parser = argparse.ArgumentParser(description="Set one slide's finding text without changing the master")
    parser.add_argument("project")
    parser.add_argument("--text", required=True)
    parser.add_argument("--element")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        element_id = set_slide_finding(project, args.text, args.element)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"finding {element_id}")
    return 0


def set_page_title(project: Project, title: str) -> None:
    text = title.strip()
    if not text:
        raise ValueError("ページタイトルが空です")
    project.slide.title = text


def _set_page_title_command(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Set the imaging slide title")
    parser.add_argument("project")
    parser.add_argument("--text", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        set_page_title(project, args.text)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"title {project.slide.title}")
    return 0


def _set_table_cell_command(argv: list[str]) -> int:
    from smart_report_builder.practical import set_table_cell

    parser = argparse.ArgumentParser(description="Set one table cell without shortening the text")
    parser.add_argument("project")
    parser.add_argument("element_id")
    parser.add_argument("row", type=int)
    parser.add_argument("column", type=int)
    parser.add_argument("--text", required=True)
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = load_project(args.project)
        set_table_cell(project, args.element_id, args.row, args.column, args.text)
        _save_outputs(project, args.project, args.layout, args.pptx)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"cell {args.element_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
