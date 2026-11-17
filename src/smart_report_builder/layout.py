"""UI にも PPTX にも依存しない配置計算。

入力が同じなら同じ LayoutResult を返す。role 名では分岐しない。
はみ出しや未割当は検出する。通常の画像はトリミングしない。
矩形 ROI を指定した拡大枠だけ、元画像上のその範囲を表示する。
注釈がある ROI には、隣の文字枠とそこへ結ぶ接続線を足す。文字は短縮しない。
"""

from __future__ import annotations

import unicodedata

from smart_report_builder.fit import contain_rect, map_normalized_rect
from smart_report_builder.models import (
    LAYOUT_SCHEMA_VERSION,
    SCHEMA_VERSION,
    Asset,
    Binding,
    CoordSpace,
    DesignMaster,
    Element,
    FitMode,
    GridNode,
    ImageFrameNode,
    Inheritance,
    LayoutResult,
    LayoutViolation,
    PlacedElement,
    Point,
    Project,
    Rect,
    Roi,
    StackDirection,
    StackNode,
    TableNode,
    TextNode,
    preview_mode_of,
)

_EPS = 1e-6
_MIN_FRAME_PT = 48.0


class UnsupportedFitModeError(ValueError):
    """cover など、未対応の表示モード。元画像の無断トリミングはしない。"""


def layout_slide(project: Project) -> LayoutResult:
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")

    design = project.design_master
    violations: list[LayoutViolation] = []
    if project.content_master.design_master_id != design.id:
        violations.append(
            LayoutViolation(
                code="design_mismatch",
                element_id=project.content_master.id,
                message="内容マスターが参照するデザインマスターと一致しない",
            )
        )
    if project.slide.content_master_id != project.content_master.id:
        violations.append(
            LayoutViolation(
                code="master_mismatch",
                element_id=project.slide.id,
                message="スライドが参照する内容マスターと一致しない",
            )
        )

    assets = {asset.id: asset for asset in project.assets}
    bindings = _bindings_by_element(project.slide.bindings, violations)
    elements: list[PlacedElement] = []
    image_assets: dict[str, Asset] = {}
    bounds = _content_bounds(design)
    _place(
        project.content_master.root,
        bounds,
        assets,
        bindings,
        elements,
        violations,
        image_assets,
    )
    note_bounds = bounds if design.body is not None else Rect(0, 0, design.slide_width_pt, design.slide_height_pt)
    _apply_rois(elements, project, image_assets, violations, note_bounds)
    _annotate_geometry(elements, design, violations)
    title_text = None
    if design.orientation:
        title_text = project.slide.title.strip() or design.page_title or "撮像画像"
    return LayoutResult(
        schema_version=LAYOUT_SCHEMA_VERSION,
        slide_width_pt=design.slide_width_pt,
        slide_height_pt=design.slide_height_pt,
        elements=elements,
        violations=violations,
        preview_mode=preview_mode_of(elements),
        template_path=design.template_path,
        chrome_image=design.chrome_image,
        title_text=title_text,
        title_frame=design.title_frame,
        title_font=design.title_font,
        title_font_pt=design.title_font_pt,
        title_color=design.title_color,
        title_shape_name=design.title_shape_name,
    )


def _content_bounds(design: DesignMaster) -> Rect:
    if design.body is not None:
        return design.body
    margin = design.margin_pt
    return Rect(
        x=margin,
        y=margin,
        width=design.slide_width_pt - (2 * margin),
        height=design.slide_height_pt - (2 * margin),
    )


def _bindings_by_element(
    bindings: list[Binding],
    violations: list[LayoutViolation],
) -> dict[str, Binding]:
    found: dict[str, Binding] = {}
    conflicts: set[str] = set()
    for binding in bindings:
        element_id = binding.element_id
        if element_id in found or element_id in conflicts:
            conflicts.add(element_id)
            violations.append(
                LayoutViolation(
                    code="binding_conflict",
                    element_id=element_id,
                    message="同じ要素への割当が複数あるため、どちらも適用していない",
                )
            )
        else:
            found[element_id] = binding
    for element_id in conflicts:
        found.pop(element_id, None)
    return found


def _place(
    node: Element,
    rect: Rect,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
    elements: list[PlacedElement],
    violations: list[LayoutViolation],
    image_assets: dict[str, Asset],
    group: Rect | None = None,
) -> None:
    if isinstance(node, StackNode):
        _place_stack(node, rect, assets, bindings, elements, violations, image_assets)
        return
    if isinstance(node, GridNode):
        _place_grid(node, rect, assets, bindings, elements, violations, image_assets)
        return
    if isinstance(node, ImageFrameNode):
        _place_image(
            node,
            rect,
            assets,
            bindings,
            elements,
            violations,
            image_assets,
            group if group is not None else rect,
        )
        return
    if isinstance(node, TextNode):
        _place_text(node, rect, bindings, elements)
        return
    if isinstance(node, TableNode):
        _place_table(node, rect, elements)
        return
    raise TypeError(f"unknown element: {type(node)!r}")


def _place_stack(
    node: StackNode,
    rect: Rect,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
    elements: list[PlacedElement],
    violations: list[LayoutViolation],
    image_assets: dict[str, Asset],
) -> None:
    children = node.children
    if not children:
        return
    if _is_free_canvas(node):
        _place_free_frames(node, rect, assets, bindings, elements, violations, image_assets)
        return
    sizes = _axis_sizes(node, rect, assets, bindings)
    horizontal = node.direction == StackDirection.HORIZONTAL
    cursor = rect.x if horizontal else rect.y
    for child, raw in zip(children, sizes, strict=True):
        size = raw if raw >= 0 else 0.0
        if raw < -_EPS:
            violations.append(
                LayoutViolation(
                    code="overflow",
                    element_id=child.id,
                    message="配分サイズが負になった",
                )
            )
        if horizontal:
            child_rect = Rect(cursor, rect.y, size, rect.height)
        else:
            child_rect = Rect(rect.x, cursor, rect.width, size)
        cursor += size + node.gap_pt
        _place(child, child_rect, assets, bindings, elements, violations, image_assets, rect)


def _axis_sizes(
    node: StackNode,
    rect: Rect,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
) -> list[float]:
    count = len(node.children)
    gap_total = node.gap_pt * (count - 1)
    if node.direction == StackDirection.HORIZONTAL:
        available = rect.width - gap_total
        if node.emphasize_first and count > 1:
            first = available / 2
            rest = (available - first) / (count - 1)
            return [first, *([rest] * (count - 1))]
        if node.track_aspect:
            weights = [
                _aspect_weight(child, assets, bindings, horizontal=True)
                for child in node.children
            ]
            return _share(available, weights)
        each = available / count
        return [each] * count

    fixed = 0.0
    flex_indexes: list[int] = []
    flags: list[float | None] = []
    for index, child in enumerate(node.children):
        if isinstance(child, (TextNode, TableNode)):
            flags.append(child.height_pt)
            fixed += child.height_pt
        else:
            flags.append(None)
            flex_indexes.append(index)
    remain = rect.height - gap_total - fixed
    if node.emphasize_first and len(flex_indexes) > 1:
        first = remain / 2
        rest = (remain - first) / (len(flex_indexes) - 1)
        flags[flex_indexes[0]] = first
        for index in flex_indexes[1:]:
            flags[index] = rest
        return [0.0 if flag is None else flag for flag in flags]
    if node.track_aspect and flex_indexes:
        weights = [
            _aspect_weight(node.children[index], assets, bindings, horizontal=False)
            for index in flex_indexes
        ]
        shared = _share(remain, weights)
        for index, size in zip(flex_indexes, shared, strict=True):
            flags[index] = size
        return [0.0 if flag is None else flag for flag in flags]
    flex = remain / len(flex_indexes) if flex_indexes else 0.0
    return [flex if flag is None else flag for flag in flags]


def _aspect_weight(
    node: Element,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
    *,
    horizontal: bool,
) -> float:
    if not isinstance(node, ImageFrameNode) or node.fit_mode != FitMode.CONTAIN:
        return 1.0
    binding = bindings.get(node.id)
    if binding is None or binding.asset_id is None:
        return 1.0
    asset = assets.get(binding.asset_id)
    if asset is None or asset.width_px <= 0 or asset.height_px <= 0:
        return 1.0
    if horizontal:
        return asset.width_px / asset.height_px
    return asset.height_px / asset.width_px


def _share(available: float, weights: list[float]) -> list[float]:
    total = sum(weight if weight > 0 else 1.0 for weight in weights)
    if not weights:
        return []
    usable = [weight if weight > 0 else 1.0 for weight in weights]
    if abs(total) <= _EPS:
        each = available / len(usable)
        return [each] * len(usable)
    return [available * weight / total for weight in usable]


def _place_grid(
    node: GridNode,
    rect: Rect,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
    elements: list[PlacedElement],
    violations: list[LayoutViolation],
    image_assets: dict[str, Asset],
) -> None:
    children = node.children
    if not children:
        return
    if _is_free_canvas(node):
        _place_free_frames(node, rect, assets, bindings, elements, violations, image_assets)
        return
    columns = node.columns
    if columns < 1:
        violations.append(
            LayoutViolation(
                code="overflow",
                element_id=node.id,
                message="格子の列数が不正",
            )
        )
        return
    rows = (len(children) + columns - 1) // columns
    cell_w = (rect.width - node.gap_pt * (columns - 1)) / columns
    cell_h = (rect.height - node.gap_pt * (rows - 1)) / rows
    for index, child in enumerate(children):
        column = index % columns
        row = index // columns
        if cell_w < -_EPS or cell_h < -_EPS:
            violations.append(
                LayoutViolation(
                    code="overflow",
                    element_id=child.id,
                    message="配分サイズが負になった",
                )
            )
        width = cell_w if cell_w >= 0 else 0.0
        height = cell_h if cell_h >= 0 else 0.0
        child_rect = Rect(
            rect.x + column * (width + node.gap_pt),
            rect.y + row * (height + node.gap_pt),
            width,
            height,
        )
        _place(child, child_rect, assets, bindings, elements, violations, image_assets, rect)


def _is_free_canvas(node: StackNode | GridNode) -> bool:
    if not node.children or not all(isinstance(child, ImageFrameNode) for child in node.children):
        return False
    return any(child.free_rect is not None for child in node.children)


def _place_free_frames(
    node: StackNode | GridNode,
    rect: Rect,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
    elements: list[PlacedElement],
    violations: list[LayoutViolation],
    image_assets: dict[str, Asset],
) -> None:
    for child in node.children:
        if not isinstance(child, ImageFrameNode):
            continue
        box = child.free_rect if child.free_rect is not None else Rect(0, 0, 1, 1)
        child_rect = Rect(
            rect.x + box.x * rect.width,
            rect.y + box.y * rect.height,
            box.width * rect.width,
            box.height * rect.height,
        )
        _place_image(child, child_rect, assets, bindings, elements, violations, image_assets, rect)


def _place_image(
    node: ImageFrameNode,
    rect: Rect,
    assets: dict[str, Asset],
    bindings: dict[str, Binding],
    elements: list[PlacedElement],
    violations: list[LayoutViolation],
    image_assets: dict[str, Asset],
    group: Rect,
) -> None:
    if node.fit_mode == FitMode.ROI:
        elements.append(
            PlacedElement(
                element_id=node.id,
                kind="image_frame",
                role_id=node.role_id,
                display_name=node.display_name,
                frame=rect,
                content_rect=None,
                text=None,
                asset_path=None,
                fit_mode=FitMode.ROI.value,
                group_frame=group,
            )
        )
        return
    if node.fit_mode != FitMode.CONTAIN:
        raise UnsupportedFitModeError(
            f"fit mode '{node.fit_mode.value}' は未実装。"
            "画像をトリミングせず処理を止めた。対応しているのは contain と roi です。"
        )

    binding = bindings.get(node.id)
    asset: Asset | None = None
    if binding is None or binding.asset_id is None:
        violations.append(
            LayoutViolation(
                code="unassigned_image",
                element_id=node.id,
                message="画像枠に素材が割り当てられていない",
            )
        )
    else:
        asset = assets.get(binding.asset_id)
        if asset is None:
            violations.append(
                LayoutViolation(
                    code="missing_asset",
                    element_id=node.id,
                    message="割当先の素材が見つからない",
                )
            )

    content: Rect | None = None
    asset_path = asset.path if asset is not None else None
    if rect.width <= _EPS or rect.height <= _EPS:
        violations.append(
            LayoutViolation(
                code="overflow",
                element_id=node.id,
                message="画像枠の幅または高さが確保できない",
            )
        )
    elif asset is not None and (asset.width_px <= 0 or asset.height_px <= 0):
        violations.append(
            LayoutViolation(
                code="invalid_image_size",
                element_id=node.id,
                message="画像のピクセル寸法が不正",
            )
        )
    elif asset is not None:
        content = contain_rect(rect, asset.width_px, asset.height_px)
        image_assets[node.id] = asset

    elements.append(
        PlacedElement(
            element_id=node.id,
            kind="image_frame",
            role_id=node.role_id,
            display_name=node.display_name,
            frame=rect,
            content_rect=content,
            text=None,
            asset_path=asset_path,
            fit_mode=FitMode.CONTAIN.value,
            group_frame=group,
        )
    )


def _place_table(node: TableNode, rect: Rect, elements: list[PlacedElement]) -> None:
    rows = [list(node.headers), *([list(row) for row in node.rows])]
    elements.append(
        PlacedElement(
            element_id=node.id,
            kind="table",
            role_id="table",
            display_name=node.display_name,
            frame=rect,
            content_rect=None,
            text=None,
            asset_path=None,
            fit_mode=FitMode.CONTAIN.value,
            table_rows=rows,
        )
    )


def _place_text(
    node: TextNode,
    rect: Rect,
    bindings: dict[str, Binding],
    elements: list[PlacedElement],
) -> None:
    binding = bindings.get(node.id)
    if binding is not None and binding.text is not None:
        text = binding.text
    else:
        text = node.text
    elements.append(
        PlacedElement(
            element_id=node.id,
            kind="text",
            role_id=node.role_id,
            display_name=node.display_name,
            frame=rect,
            content_rect=None,
            text=text,
            asset_path=None,
            fit_mode=FitMode.CONTAIN.value,
        )
    )


_NOTE_WIDTH_PT = 180.0
_NOTE_HEIGHT_PT = 64.0
_NOTE_GAP_PT = 12.0
_OVERLAY_KINDS = {"roi", "roi_label", "connector"}


def _apply_rois(
    elements: list[PlacedElement],
    project: Project,
    image_assets: dict[str, Asset],
    violations: list[LayoutViolation],
    bounds: Rect,
) -> None:
    rois = project.slide.rois
    zoom_targets: dict[str, list[Roi]] = {}
    for roi in rois:
        if roi.zoom_element_id is not None:
            zoom_targets.setdefault(roi.zoom_element_id, []).append(roi)

    for roi in rois:
        roi = _effective_roi(project, roi, violations)
        if roi.zoom_element_id is not None and len(zoom_targets[roi.zoom_element_id]) > 1:
            violations.append(
                LayoutViolation(
                    code="roi_conflict",
                    element_id=roi.id,
                    message="同じ拡大枠への ROI が複数あるため、どちらも適用していない",
                )
            )
            continue
        source = _element_by_id(elements, roi.source_element_id)
        asset = image_assets.get(roi.source_element_id)
        if source is None or source.kind != "image_frame" or source.content_rect is None or asset is None:
            violations.append(
                LayoutViolation(
                    code="roi_unmapped",
                    element_id=roi.id,
                    message="ROI を載せる元画像の表示矩形がない",
                )
            )
            continue
        normalized = _normalized_roi(roi, asset, violations)
        if normalized is None:
            continue
        elements.append(
            PlacedElement(
                element_id=roi.id,
                kind="roi",
                role_id="roi",
                display_name=roi.name,
                frame=map_normalized_rect(source.content_rect, normalized),
                content_rect=None,
                text=None,
                asset_path=None,
                fit_mode=FitMode.ROI.value,
                crop=normalized,
                source_element_id=source.element_id,
            )
        )
        _append_roi_note(elements, roi, elements[-1].frame, bounds)
        if roi.zoom_element_id is None:
            continue
        zoom = _element_by_id(elements, roi.zoom_element_id)
        if zoom is None or zoom.fit_mode != FitMode.ROI.value:
            violations.append(
                LayoutViolation(
                    code="roi_unmapped",
                    element_id=roi.id,
                    message="ROI の拡大先が roi 表示の画像枠ではない",
                )
            )
            continue
        _replace_element(
            elements,
            PlacedElement(
                element_id=zoom.element_id,
                kind="image_frame",
                role_id=zoom.role_id,
                display_name=zoom.display_name,
                frame=zoom.frame,
                content_rect=contain_rect(
                    zoom.frame,
                    normalized.width * asset.width_px,
                    normalized.height * asset.height_px,
                ),
                text=None,
                asset_path=asset.path,
                fit_mode=FitMode.ROI.value,
                crop=normalized,
                source_element_id=source.element_id,
                group_frame=zoom.group_frame,
            ),
        )


def _effective_roi(project: Project, roi: Roi, violations: list[LayoutViolation]) -> Roi:
    if roi.master_roi_id is None or roi.inheritance == Inheritance.DETACHED:
        return roi
    master = next(
        (item for item in project.content_master.master_rois if item.id == roi.master_roi_id),
        None,
    )
    if master is None:
        violations.append(
            LayoutViolation(
                code="master_missing",
                element_id=roi.id,
                message="参照するマスター ROI が見つからない",
            )
        )
        return roi
    if roi.inheritance == Inheritance.RELATIVE:
        x = master.x + roi.dx
        y = master.y + roi.dy
        width = master.width + roi.dw
        height = master.height + roi.dh
    else:
        x, y, width, height = master.x, master.y, master.width, master.height
    return Roi(
        id=roi.id,
        name=roi.name,
        source_element_id=roi.source_element_id,
        x=x,
        y=y,
        width=width,
        height=height,
        zoom_element_id=roi.zoom_element_id,
        coord_space=master.coord_space,
        note=roi.note,
        note_dx=roi.note_dx,
        note_dy=roi.note_dy,
        master_roi_id=roi.master_roi_id,
        inheritance=roi.inheritance,
        dx=roi.dx,
        dy=roi.dy,
        dw=roi.dw,
        dh=roi.dh,
    )


def _normalized_roi(
    roi: Roi,
    asset: Asset,
    violations: list[LayoutViolation],
) -> Rect | None:
    if roi.coord_space == CoordSpace.PIXEL:
        if asset.width_px <= 0 or asset.height_px <= 0:
            violations.append(
                LayoutViolation(
                    code="roi_unmapped",
                    element_id=roi.id,
                    message="ピクセル ROI を正規化するための画像寸法がない",
                )
            )
            return None
        normalized = Rect(
            x=roi.x / asset.width_px,
            y=roi.y / asset.height_px,
            width=roi.width / asset.width_px,
            height=roi.height / asset.height_px,
        )
    elif roi.coord_space == CoordSpace.NORMALIZED:
        normalized = Rect(roi.x, roi.y, roi.width, roi.height)
    else:
        violations.append(
            LayoutViolation(
                code="roi_unmapped",
                element_id=roi.id,
                message="未対応の ROI 座標方式",
            )
        )
        return None
    inside = (
        normalized.width > _EPS
        and normalized.height > _EPS
        and normalized.x >= -_EPS
        and normalized.y >= -_EPS
        and normalized.x + normalized.width <= 1 + _EPS
        and normalized.y + normalized.height <= 1 + _EPS
    )
    if not inside:
        violations.append(
            LayoutViolation(
                code="roi_out_of_bounds",
                element_id=roi.id,
                message="ROI が元画像の外にはみ出すため、適用していない",
            )
        )
        return None
    return normalized


def _append_roi_note(
    elements: list[PlacedElement],
    roi: Roi,
    roi_frame: Rect,
    bounds: Rect,
) -> None:
    note = roi.note.strip()
    if not note:
        return
    label_frame = _placed_note_frame(roi, roi_frame, bounds)
    start, end = _connector_points(roi_frame, label_frame)
    elements.append(
        PlacedElement(
            element_id=f"{roi.id}-connector",
            kind="connector",
            role_id="connector",
            display_name=f"{roi.name} の接続線",
            frame=_line_frame(start, end),
            text=None,
            source_element_id=roi.id,
            line_start=start,
            line_end=end,
        )
    )
    elements.append(
        PlacedElement(
            element_id=f"{roi.id}-note",
            kind="roi_label",
            role_id="roi_note",
            display_name=f"{roi.name} の注釈",
            frame=label_frame,
            text=note,
            source_element_id=roi.id,
        )
    )


def _placed_note_frame(roi: Roi, roi_frame: Rect, bounds: Rect) -> Rect:
    anchored = _anchored_note_frame(roi_frame, bounds)
    if roi.note_dx is None or roi.note_dy is None:
        return anchored
    return _clamp_note_frame(
        Rect(anchored.x + roi.note_dx, anchored.y + roi.note_dy, anchored.width, anchored.height),
        bounds,
    )


def _clamp_note_frame(frame: Rect, bounds: Rect) -> Rect:
    return Rect(
        min(max(frame.x, bounds.x), max(bounds.x, bounds.x + bounds.width - frame.width)),
        min(max(frame.y, bounds.y), max(bounds.y, bounds.y + bounds.height - frame.height)),
        frame.width,
        frame.height,
    )


def _anchored_note_frame(roi: Rect, bounds: Rect) -> Rect:
    """ROI の隣に、決まった大きさの注釈枠を置く。入る位置を右、左、下、上の順で選ぶ。"""
    vertical_middle = roi.y + roi.height / 2 - _NOTE_HEIGHT_PT / 2
    horizontal_middle = roi.x + roi.width / 2 - _NOTE_WIDTH_PT / 2
    candidates = (
        Rect(roi.x + roi.width + _NOTE_GAP_PT, vertical_middle, _NOTE_WIDTH_PT, _NOTE_HEIGHT_PT),
        Rect(roi.x - _NOTE_GAP_PT - _NOTE_WIDTH_PT, vertical_middle, _NOTE_WIDTH_PT, _NOTE_HEIGHT_PT),
        Rect(horizontal_middle, roi.y + roi.height + _NOTE_GAP_PT, _NOTE_WIDTH_PT, _NOTE_HEIGHT_PT),
        Rect(horizontal_middle, roi.y - _NOTE_GAP_PT - _NOTE_HEIGHT_PT, _NOTE_WIDTH_PT, _NOTE_HEIGHT_PT),
    )
    for frame in candidates:
        if not _outside(frame, bounds):
            return frame
    fallback = candidates[0]
    return Rect(
        min(max(fallback.x, bounds.x), max(bounds.x, bounds.x + bounds.width - fallback.width)),
        min(max(fallback.y, bounds.y), max(bounds.y, bounds.y + bounds.height - fallback.height)),
        fallback.width,
        fallback.height,
    )


def _connector_points(roi: Rect, label: Rect) -> tuple[Point, Point]:
    roi_center_x = roi.x + roi.width / 2
    roi_center_y = roi.y + roi.height / 2
    label_center_x = label.x + label.width / 2
    label_center_y = label.y + label.height / 2
    if abs(label_center_x - roi_center_x) >= abs(label_center_y - roi_center_y):
        if label_center_x >= roi_center_x:
            return Point(roi.x + roi.width, roi_center_y), Point(label.x, label_center_y)
        return Point(roi.x, roi_center_y), Point(label.x + label.width, label_center_y)
    if label_center_y >= roi_center_y:
        return Point(roi_center_x, roi.y + roi.height), Point(label_center_x, label.y)
    return Point(roi_center_x, roi.y), Point(label_center_x, label.y + label.height)


def _line_frame(start: Point, end: Point) -> Rect:
    return Rect(
        min(start.x, end.x),
        min(start.y, end.y),
        abs(end.x - start.x),
        abs(end.y - start.y),
    )


def _element_by_id(elements: list[PlacedElement], element_id: str) -> PlacedElement | None:
    for element in elements:
        if element.element_id == element_id:
            return element
    return None


def _replace_element(elements: list[PlacedElement], replacement: PlacedElement) -> None:
    for index, element in enumerate(elements):
        if element.element_id == replacement.element_id:
            elements[index] = replacement
            return


def _annotate_geometry(
    elements: list[PlacedElement],
    design: DesignMaster,
    violations: list[LayoutViolation],
) -> None:
    slide = Rect(0, 0, design.slide_width_pt, design.slide_height_pt)
    for element in elements:
        if _outside(element.frame, slide):
            violations.append(
                LayoutViolation(
                    code="overflow",
                    element_id=element.element_id,
                    message="要素がスライドの外にはみ出している",
                )
            )
        if element.kind in {"image_frame", "text"} and _tight(element.frame):
            violations.append(
                LayoutViolation(
                    code="overflow",
                    element_id=element.element_id,
                    message="枠が小さすぎる",
                )
            )
        if element.content_rect is not None and _outside(element.content_rect, element.frame):
            violations.append(
                LayoutViolation(
                    code="overflow",
                    element_id=element.element_id,
                    message="描画矩形が画像枠の外にはみ出している",
                )
            )
        if element.kind == "text" and _text_is_clipped(element.frame, element.text or ""):
            violations.append(
                LayoutViolation(
                    code="text_overflow",
                    element_id=element.element_id,
                    message="文章が枠に入りきらないため、末尾が切れて見えることがあります。文章は省略していません",
                )
            )
    for index, left in enumerate(elements):
        for right in elements[index + 1 :]:
            if left.kind in _OVERLAY_KINDS or right.kind in _OVERLAY_KINDS:
                continue
            if _overlap(left.frame, right.frame):
                violations.append(
                    LayoutViolation(
                        code="overlap",
                        element_id=right.element_id,
                        message=f"{left.element_id} と重なっている",
                    )
                )


_TEXT_FONT_PT = 16.0


def _text_is_clipped(frame: Rect, text: str) -> bool:
    """16pt・行高 1 の見積もり。文字は削らず、枠より多くなるときだけ真にする。"""
    if not text or frame.width <= _EPS or frame.height <= _EPS:
        return False
    capacity = int(frame.height // _TEXT_FONT_PT)
    if capacity < 1:
        return True
    needed = 0
    for paragraph in text.split("\n"):
        needed += _wrapped_lines(paragraph, frame.width)
    return needed > capacity


def _wrapped_lines(paragraph: str, width: float) -> int:
    if paragraph == "":
        return 1
    lines = 1
    used = 0.0
    for char in paragraph:
        advance = _char_width(char)
        if used > 0 and used + advance > width + _EPS:
            lines += 1
            used = advance
        else:
            used += advance
    return lines


def _char_width(char: str) -> float:
    if char == "\t":
        return _TEXT_FONT_PT * 2
    width = unicodedata.east_asian_width(char)
    if width in {"F", "W", "A"}:
        return _TEXT_FONT_PT
    return _TEXT_FONT_PT * 0.5


def _tight(rect: Rect) -> bool:
    return (0 < rect.width < _MIN_FRAME_PT) or (0 < rect.height < _MIN_FRAME_PT)


def _outside(rect: Rect, bounds: Rect) -> bool:
    return (
        rect.x < bounds.x - _EPS
        or rect.y < bounds.y - _EPS
        or rect.x + rect.width > bounds.x + bounds.width + _EPS
        or rect.y + rect.height > bounds.y + bounds.height + _EPS
    )


def _overlap(left: Rect, right: Rect) -> bool:
    if left.width <= 0 or left.height <= 0 or right.width <= 0 or right.height <= 0:
        return False
    separated = (
        left.x + left.width <= right.x + _EPS
        or right.x + right.width <= left.x + _EPS
        or left.y + left.height <= right.y + _EPS
        or right.y + right.height <= left.y + _EPS
    )
    return not separated
