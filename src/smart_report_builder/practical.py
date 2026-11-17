"""自動割当の候補、レイアウト案、ROI の継承、表。

候補と案は、このモジュールを呼んだだけでは保存しない。
適用関数はプロジェクトを書き換えるが、ファイルには書かない。
"""

from __future__ import annotations

from pathlib import Path

from smart_report_builder.layout import layout_slide
from smart_report_builder.models import (
    Element,
    Dataset,
    FitMode,
    GridNode,
    ImageFrameNode,
    Inheritance,
    MasterRoi,
    Project,
    Rect,
    Roi,
    StackDirection,
    StackNode,
    TableNode,
    project_from_dict,
    project_to_dict,
)

_EPS = 1e-6


class AssignmentCandidate:
    def __init__(self, status: str, element_id: str, asset_id: str, asset_name: str, reason: str) -> None:
        self.status = status
        self.element_id = element_id
        self.asset_id = asset_id
        self.asset_name = asset_name
        self.reason = reason


class LayoutProposal:
    def __init__(self, variant_id: str, name: str, reason: str, *, selected: bool) -> None:
        self.variant_id = variant_id
        self.name = name
        self.reason = reason
        self.selected = selected


def assignment_candidates(project: Project) -> list[AssignmentCandidate]:
    """空の通常表示の枠へ、未使用の素材の候補を出す。割り当てはしない。"""
    used = {item.asset_id for item in project.slide.bindings if item.asset_id}
    bound = {item.element_id: item.asset_id for item in project.slide.bindings}
    unused = [asset for asset in project.assets if asset.id not in used]
    found: list[AssignmentCandidate] = []
    for frame in _image_frames(project.content_master.root):
        if frame.fit_mode != FitMode.CONTAIN:
            continue
        if bound.get(frame.id):
            continue
        exact = [asset for asset in unused if _exact_match(frame, asset)]
        if len(exact) == 1:
            asset = exact[0]
            found.append(
                AssignmentCandidate("ready", frame.id, asset.id, asset.display_name, "表示名が一致")
            )
            continue
        if len(exact) > 1:
            for asset in exact:
                found.append(
                    AssignmentCandidate(
                        "confirm",
                        frame.id,
                        asset.id,
                        asset.display_name,
                        "一致する素材が複数ある",
                    )
                )
            continue
        partial = [asset for asset in unused if _partial_match(frame, asset)]
        for asset in partial:
            found.append(
                AssignmentCandidate(
                    "confirm",
                    frame.id,
                    asset.id,
                    asset.display_name,
                    "名前の一部だけ一致",
                )
            )
    return found


def apply_assignment_candidate(project: Project, element_id: str, asset_id: str) -> str:
    match = next(
        (
            item
            for item in assignment_candidates(project)
            if item.element_id == element_id and item.asset_id == asset_id and item.status in {"ready", "confirm"}
        ),
        None,
    )
    if match is None:
        raise ValueError("この組み合わせは候補にありません")
    from smart_report_builder.roi_edit import assign_registered_asset

    return assign_registered_asset(project, element_id, asset_id)


def propose_variants(project: Project) -> list[LayoutProposal]:
    """標準案がはみ出すときだけ、最大3件の案を返す。プロジェクトは変えない。"""
    standard = layout_slide(project)
    proposals = [LayoutProposal("standard", "標準", "今の配置", selected=True)]
    if not any(item.code == "overflow" for item in standard.violations):
        return proposals
    options = (
        ("equal", "等分", "縦横比による偏りをやめ、枠を等分する"),
        ("emphasize", "主画像", "先頭の画像枠を広くする"),
        ("grid", "格子", "画像を格子に並べ、説明文は後ろに残す"),
    )
    standard_signature = _signature(standard)
    for variant_id, name, reason in options:
        if len(proposals) >= 3:
            break
        clone = project_from_dict(project_to_dict(project))
        try:
            apply_variant(clone, variant_id)
        except ValueError:
            continue
        result = layout_slide(clone)
        if _signature(result) == standard_signature:
            continue
        proposals.append(LayoutProposal(variant_id, name, reason, selected=False))
    return proposals


def apply_variant(project: Project, variant_id: str) -> str:
    if variant_id == "standard":
        raise ValueError("標準案はすでに選ばれています")
    if variant_id not in {"equal", "emphasize", "grid"}:
        raise ValueError("レイアウト案が見つからない")
    root, index, container = _image_container(project)
    replacement = _variant_container(container, variant_id)
    has_free = any(isinstance(child, ImageFrameNode) and child.free_rect is not None for child in container.children)
    if _container_same(container, replacement) and not has_free:
        raise ValueError("この案はすでに選ばれています")
    for child in replacement.children:
        if isinstance(child, ImageFrameNode):
            child.free_rect = None
    root.children[index] = replacement
    return variant_id


def capture_master_roi(project: Project, roi_id: str) -> str:
    roi = _roi(project, roi_id)
    master_id = _next_id("master-roi-", [item.id for item in project.content_master.master_rois])
    project.content_master.master_rois.append(
        MasterRoi(
            id=master_id,
            name=roi.name,
            source_element_id=roi.source_element_id,
            x=roi.x,
            y=roi.y,
            width=roi.width,
            height=roi.height,
            coord_space=roi.coord_space,
            note=roi.note,
        )
    )
    roi.master_roi_id = master_id
    roi.inheritance = Inheritance.INHERIT
    roi.dx = 0.0
    roi.dy = 0.0
    roi.dw = 0.0
    roi.dh = 0.0
    return master_id


def update_master_roi(project: Project, master_id: str, x: float, y: float, width: float, height: float) -> None:
    master = _master(project, master_id)
    master.x = x
    master.y = y
    master.width = width
    master.height = height


def apply_master_roi(project: Project, master_id: str, element_ids: list[str]) -> tuple[int, int]:
    """選んだ枠へマスター ROI を継承で展開する。補正済みは上書きしない。"""
    master = _master(project, master_id)
    frames = {item.id: item for item in _image_frames(project.content_master.root)}
    for element_id in element_ids:
        if element_id not in frames:
            raise ValueError(f"画像枠が見つからない: {element_id}")
    applied = 0
    skipped = 0
    for element_id in element_ids:
        existing = [
            item
            for item in project.slide.rois
            if item.master_roi_id == master_id and item.source_element_id == element_id
        ]
        if existing and any(item.inheritance != Inheritance.INHERIT for item in existing):
            skipped += 1
            continue
        if existing:
            skipped += 1
            continue
        project.slide.rois.append(
            Roi(
                id=_next_id("roi-", [item.id for item in project.slide.rois]),
                name=master.name,
                source_element_id=element_id,
                x=master.x,
                y=master.y,
                width=master.width,
                height=master.height,
                coord_space=master.coord_space,
                note=master.note,
                master_roi_id=master.id,
                inheritance=Inheritance.INHERIT,
            )
        )
        applied += 1
    return applied, skipped


def record_roi_move(project: Project, roi: Roi) -> None:
    """継承中の ROI を動かすと、その枠だけ相対補正にする。マスターは変えない。"""
    if roi.master_roi_id is None:
        return
    master = next((item for item in project.content_master.master_rois if item.id == roi.master_roi_id), None)
    if master is None:
        roi.inheritance = Inheritance.DETACHED
        return
    if roi.inheritance == Inheritance.DETACHED:
        return
    dx = roi.x - master.x
    dy = roi.y - master.y
    dw = roi.width - master.width
    dh = roi.height - master.height
    if abs(dx) <= _EPS and abs(dy) <= _EPS and abs(dw) <= _EPS and abs(dh) <= _EPS:
        roi.inheritance = Inheritance.INHERIT
        roi.dx = 0.0
        roi.dy = 0.0
        roi.dw = 0.0
        roi.dh = 0.0
        return
    roi.inheritance = Inheritance.RELATIVE
    roi.dx = dx
    roi.dy = dy
    roi.dw = dw
    roi.dh = dh


def add_measurement_table(project: Project) -> str:
    root = project.content_master.root
    if not isinstance(root, StackNode):
        raise ValueError("この配置には表を追加できません")
    if any(isinstance(child, TableNode) for child in _walk(root)):
        raise ValueError("表はすでにあります")
    table = TableNode(
        id="table-measure",
        display_name="測定",
        headers=["項目", "値"],
        rows=[["結果", ""]],
        height_pt=72.0,
    )
    root.children.append(table)
    return table.id


_TABLE_ROW_PT = 36.0


def add_table_row(project: Project, element_id: str) -> int:
    table = next((item for item in _walk(project.content_master.root) if isinstance(item, TableNode) and item.id == element_id), None)
    if table is None:
        raise ValueError("表が見つからない")
    columns = len(table.headers)
    if columns < 1:
        raise ValueError("表の列が見つからない")
    table.rows.append([""] * columns)
    table.height_pt += _TABLE_ROW_PT
    return len(table.rows)


def _image_block(project: Project) -> StackNode | GridNode:
    root = project.content_master.root
    if not isinstance(root, StackNode):
        raise ValueError("この配置には画像枠を追加できません")
    filled = next(
        (
            child
            for child in root.children
            if isinstance(child, (StackNode, GridNode)) and _image_frames(child)
        ),
        None,
    )
    if filled is not None:
        return filled
    empty = next((child for child in root.children if isinstance(child, (StackNode, GridNode))), None)
    if empty is None:
        raise ValueError("この配置には画像枠を追加できません")
    return empty


def add_image_frame(project: Project) -> str:
    container = _image_block(project)
    frame_id = _next_id("frame-", [item.id for item in _walk(project.content_master.root)])
    number = frame_id.removeprefix("frame-")
    free = any(isinstance(child, ImageFrameNode) and child.free_rect is not None for child in container.children)
    container.children.append(
        ImageFrameNode(
            id=frame_id,
            role_id="image",
            display_name=f"画像{number}",
            fit_mode=FitMode.CONTAIN,
            free_rect=Rect(0.7, 0.7, 0.3, 0.3) if free else None,
        )
    )
    return frame_id


_FRAME_KINDS = {
    "image": ("image", FitMode.CONTAIN, "画像"),
    "overall": ("overall", FitMode.CONTAIN, "全体画像"),
    "comparison": ("comparison", FitMode.CONTAIN, "比較画像"),
    "zoom": ("zoom", FitMode.ROI, "拡大画像"),
}


def image_frame_kind(frame: ImageFrameNode) -> str:
    """画像枠の種類。拡大は表示モード、それ以外は役割で決める。"""
    if frame.fit_mode == FitMode.ROI:
        return "zoom"
    if frame.role_id in {"overall", "comparison", "image"}:
        return frame.role_id
    return "image"


def set_image_frame_kind(project: Project, element_id: str, kind: str) -> str:
    """選択した画像枠の種類を変える。位置と素材の割当は残す。

    拡大にすると、その枠に描いていた ROI は外す。拡大先だった枠を通常の画像に戻すと、
    その枠への連動だけ外し、元画像の上の ROI 矩形は残す。
    """
    if kind not in _FRAME_KINDS:
        raise ValueError("種類は画像、全体画像、比較画像、拡大のいずれかです")
    frame = _find_image_frame(project.content_master.root, element_id)
    if frame is None:
        raise ValueError("画像枠が見つからない")
    if frame.fit_mode not in {FitMode.CONTAIN, FitMode.ROI}:
        raise ValueError("この画像枠の種類は変更できません")
    previous = image_frame_kind(frame)
    if previous == kind:
        return element_id
    role_id, fit_mode, _base = _FRAME_KINDS[kind]
    taken = {
        item.display_name
        for item in _image_frames(project.content_master.root)
        if item.id != frame.id
    }
    frame.role_id = role_id
    frame.fit_mode = fit_mode
    frame.display_name = _kind_display_name(kind, frame.id, taken)
    if kind == "zoom":
        project.slide.rois = [roi for roi in project.slide.rois if roi.source_element_id != element_id]
    elif previous == "zoom":
        for roi in project.slide.rois:
            if roi.zoom_element_id == element_id:
                roi.zoom_element_id = None
    return element_id


def _kind_display_name(kind: str, frame_id: str, taken: set[str]) -> str:
    base = _FRAME_KINDS[kind][2]
    if kind == "image":
        suffix = frame_id.removeprefix("frame-")
        candidate = f"画像{suffix}" if suffix.isdigit() else "画像"
    else:
        candidate = base
    if candidate not in taken:
        return candidate
    number = 2
    while f"{base}{number}" in taken:
        number += 1
    return f"{base}{number}"


def remove_image_frame(project: Project, element_id: str) -> str:
    frame = _find_image_frame(project.content_master.root, element_id)
    if frame is None:
        raise ValueError("画像枠が見つからない")
    if frame.fit_mode not in {FitMode.CONTAIN, FitMode.ROI}:
        raise ValueError("この画像枠は削除できません")
    if not _detach_image_frame(project.content_master.root, element_id):
        raise ValueError("画像枠が見つからない")
    _drop_empty_zoom_block(project)
    project.slide.bindings = [item for item in project.slide.bindings if item.element_id != element_id]
    if frame.fit_mode == FitMode.CONTAIN:
        project.slide.rois = [item for item in project.slide.rois if item.source_element_id != element_id]
    for roi in project.slide.rois:
        if roi.zoom_element_id == element_id:
            roi.zoom_element_id = None
    return element_id


def _drop_empty_zoom_block(project: Project) -> None:
    root = project.content_master.root
    if not isinstance(root, StackNode):
        return
    root.children = [
        child
        for child in root.children
        if not (
            isinstance(child, (StackNode, GridNode))
            and child.id in {"stack-zooms", "grid-zooms"}
            and not child.children
        )
    ]


def _find_image_frame(node: Element, element_id: str) -> ImageFrameNode | None:
    if isinstance(node, ImageFrameNode) and node.id == element_id:
        return node
    if isinstance(node, (StackNode, GridNode)):
        for child in node.children:
            found = _find_image_frame(child, element_id)
            if found is not None:
                return found
    return None


def _detach_image_frame(node: Element, element_id: str) -> bool:
    if not isinstance(node, (StackNode, GridNode)):
        return False
    for index, child in enumerate(node.children):
        if isinstance(child, ImageFrameNode) and child.id == element_id:
            del node.children[index]
            return True
        if _detach_image_frame(child, element_id):
            return True
    return False


def create_dataset(project: Project, name: str, asset_ids: list[str]) -> str:
    stored = name.strip()
    if not stored:
        raise ValueError("グループ名が空です")
    if not asset_ids:
        raise ValueError("グループにする素材がありません")
    known = {asset.id for asset in project.assets}
    chosen: list[str] = []
    for asset_id in asset_ids:
        if asset_id not in known:
            raise ValueError("素材が見つからない")
        if asset_id not in chosen:
            chosen.append(asset_id)
    dataset_id = _next_id("dataset-", [item.id for item in project.datasets])
    project.datasets.append(Dataset(id=dataset_id, name=stored, asset_ids=chosen))
    return dataset_id


def add_dataset_asset(project: Project, dataset_id: str, asset_id: str) -> None:
    dataset = next((item for item in project.datasets if item.id == dataset_id), None)
    if dataset is None:
        raise ValueError("グループが見つからない")
    if not any(asset.id == asset_id for asset in project.assets):
        raise ValueError("素材が見つからない")
    if asset_id in dataset.asset_ids:
        raise ValueError("この素材はすでにそのグループに入っています")
    dataset.asset_ids.append(asset_id)


def remove_dataset_asset(project: Project, dataset_id: str, asset_id: str) -> None:
    dataset = next((item for item in project.datasets if item.id == dataset_id), None)
    if dataset is None:
        raise ValueError("グループが見つからない")
    if asset_id not in dataset.asset_ids:
        raise ValueError("この素材はそのグループに入っていません")
    dataset.asset_ids.remove(asset_id)


def add_table_column(project: Project, element_id: str) -> int:
    table = next((item for item in _walk(project.content_master.root) if isinstance(item, TableNode) and item.id == element_id), None)
    if table is None:
        raise ValueError("表が見つからない")
    table.headers.append("")
    width = len(table.headers)
    for row in table.rows:
        while len(row) < width:
            row.append("")
    return width - 1


def set_table_cell(project: Project, element_id: str, row: int, column: int, text: str) -> str:
    table = next((item for item in _walk(project.content_master.root) if isinstance(item, TableNode) and item.id == element_id), None)
    if table is None:
        raise ValueError("表が見つからない")
    if row == 0:
        if column < 0 or column >= len(table.headers):
            raise ValueError("表の列が見つからない")
        table.headers[column] = text
        return text
    body = row - 1
    if body < 0 or body >= len(table.rows):
        raise ValueError("表の行が見つからない")
    if column < 0 or column >= len(table.rows[body]):
        raise ValueError("表の列が見つからない")
    table.rows[body][column] = text
    return text


def _exact_match(frame: ImageFrameNode, asset) -> bool:
    names = {frame.display_name.casefold(), frame.role_id.casefold()}
    asset_names = {asset.display_name.casefold(), Path(asset.path).stem.casefold()}
    return bool(names & asset_names)


def _partial_match(frame: ImageFrameNode, asset) -> bool:
    haystack = f"{asset.display_name} {Path(asset.path).stem}".casefold()
    for token in (frame.display_name, frame.role_id):
        folded = token.casefold().strip()
        if len(folded) >= 2 and folded in haystack:
            return True
    return False


def _image_container(project: Project) -> tuple[StackNode, int, StackNode | GridNode]:
    root = project.content_master.root
    if not isinstance(root, StackNode):
        raise ValueError("この配置にはレイアウト案を適用できません")
    for index, child in enumerate(root.children):
        if isinstance(child, (StackNode, GridNode)) and _image_frames(child):
            return root, index, child
    raise ValueError("この配置にはレイアウト案を適用できません")


def _variant_container(container: StackNode | GridNode, variant_id: str) -> StackNode | GridNode:
    children = list(container.children)
    if variant_id == "grid":
        return GridNode(
            id=container.id if isinstance(container, GridNode) else "grid-images",
            columns=2 if len(children) > 1 else 1,
            gap_pt=container.gap_pt,
            children=children,
        )
    direction = container.direction if isinstance(container, StackNode) else StackDirection.HORIZONTAL
    return StackNode(
        id=container.id if isinstance(container, StackNode) else "stack-images",
        direction=direction,
        gap_pt=container.gap_pt,
        track_aspect=False,
        emphasize_first=variant_id == "emphasize",
        children=children,
    )


def _container_same(left: StackNode | GridNode, right: StackNode | GridNode) -> bool:
    if type(left) is not type(right):
        return False
    if isinstance(left, GridNode) and isinstance(right, GridNode):
        return left.columns == right.columns and left.children == right.children
    if isinstance(left, StackNode) and isinstance(right, StackNode):
        return (
            left.direction == right.direction
            and left.track_aspect == right.track_aspect
            and left.emphasize_first == right.emphasize_first
            and left.children == right.children
        )
    return False


def _signature(result) -> tuple:
    return tuple(
        (
            element.element_id,
            round(element.frame.x, 4),
            round(element.frame.y, 4),
            round(element.frame.width, 4),
            round(element.frame.height, 4),
        )
        for element in result.elements
        if element.kind in {"image_frame", "text", "table"}
    )


def _image_frames(node: Element) -> list[ImageFrameNode]:
    if isinstance(node, ImageFrameNode):
        return [node]
    if isinstance(node, (StackNode, GridNode)):
        found: list[ImageFrameNode] = []
        for child in node.children:
            found.extend(_image_frames(child))
        return found
    return []


def _walk(node: Element) -> list[Element]:
    found = [node]
    if isinstance(node, (StackNode, GridNode)):
        for child in node.children:
            found.extend(_walk(child))
    return found


def _roi(project: Project, roi_id: str) -> Roi:
    roi = next((item for item in project.slide.rois if item.id == roi_id), None)
    if roi is None:
        raise ValueError(f"ROI が見つからない: {roi_id}")
    return roi


def _master(project: Project, master_id: str) -> MasterRoi:
    master = next((item for item in project.content_master.master_rois if item.id == master_id), None)
    if master is None:
        raise ValueError("マスター ROI が見つからない")
    return master


def _next_id(prefix: str, used: list[str]) -> str:
    number = 1
    while f"{prefix}{number}" in used:
        number += 1
    return f"{prefix}{number}"
