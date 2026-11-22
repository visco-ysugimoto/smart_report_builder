"""自動割当の候補、レイアウト案、ROI の継承、表。

候補と案は、このモジュールを呼んだだけでは保存しない。
確定候補の一括採用と、選んだ1件の採用だけが割当を書く。確認推奨と競合は自動では選ばない。
適用関数はプロジェクトを書き換えるが、ファイルには書かない。手動で入っている割当は上書きしない。
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from pathlib import Path

from smart_report_builder.layout import layout_slide
from smart_report_builder.models import (
    Element,
    Dataset,
    FitMode,
    GridNode,
    Binding,
    ImageFrameNode,
    Inheritance,
    MasterRoi,
    Project,
    Rect,
    Roi,
    StackDirection,
    StackNode,
    TableNode,
    TextNode,
    project_from_dict,
    project_to_dict,
)

_EPS = 1e-6


# 画面と IPC が共通で使う状態。確定候補だけを一括採用できる。
STATUS_READY = "ready"
STATUS_REVIEW = "confirm"
STATUS_CONFLICT = "conflict"
LABEL_READY = "確定候補"
LABEL_REVIEW = "確認推奨"
LABEL_CONFLICT = "競合"

# 内部 role ID への同義語。呼び出し側が辞書を渡すと、この表の代わりに使う。
DEFAULT_ROLE_SYNONYMS: dict[str, tuple[str, ...]] = {
    "overall": ("全体画像", "全体", "overall"),
    "comparison": ("比較画像", "比較", "comparison"),
    "zoom": ("拡大画像", "拡大", "zoom"),
    "processed": ("処理後画像", "処理後", "処理", "processed"),
}

_TOKEN = re.compile(r"[0-9A-Za-z\u3040-\u30ff\u4e00-\u9fff]+")


class AssignmentCandidate:
    def __init__(
        self,
        status: str,
        element_id: str,
        asset_id: str,
        asset_name: str,
        reason: str,
        confidence: float = 1.0,
        label: str = "",
    ) -> None:
        self.status = status
        self.element_id = element_id
        self.asset_id = asset_id
        self.asset_name = asset_name
        self.reason = reason
        self.confidence = float(confidence)
        self.label = label or _label_for(status)


class LayoutProposal:
    def __init__(self, variant_id: str, name: str, reason: str, *, selected: bool) -> None:
        self.variant_id = variant_id
        self.name = name
        self.reason = reason
        self.selected = selected


def assignment_candidates(
    project: Project,
    synonyms: Mapping[str, Sequence[str]] | None = None,
) -> list[AssignmentCandidate]:
    """空の通常表示の枠へ、未使用の素材の候補を出す。割り当てはしない。

    確定候補は名前か役割語が1対1のときだけ。役割語が重なる、同じ枠に複数一致する、
    フォルダが複数ある場合は競合にする。フォルダ内のファイル名順は確認推奨で、自動では選ばない。
    """
    table = _synonym_table(synonyms)
    used = {item.asset_id for item in project.slide.bindings if item.asset_id}
    bound = {item.element_id: item.asset_id for item in project.slide.bindings if item.asset_id}
    frames = [
        frame
        for frame in _image_frames(project.content_master.root)
        if frame.fit_mode == FitMode.CONTAIN and frame.id not in bound
    ]
    unused = [asset for asset in project.assets if asset.id not in used]
    if any(asset.list_index is not None for asset in project.assets):
        unused = [asset for asset in unused if asset.list_index is None]
    found: list[AssignmentCandidate] = []
    taken_assets: set[str] = set()
    taken_frames: set[str] = set()

    for frame in frames:
        exact = [asset for asset in unused if _exact_match(frame, asset)]
        if len(exact) == 1:
            found.append(_make_candidate(STATUS_READY, frame, exact[0], "表示名が一致", 1.0))
            taken_assets.add(exact[0].id)
            taken_frames.add(frame.id)
        elif len(exact) > 1:
            for asset in exact:
                found.append(
                    _make_candidate(STATUS_CONFLICT, frame, asset, "同じ枠に一致する素材が複数ある", 0.4)
                )
                taken_assets.add(asset.id)
            taken_frames.add(frame.id)

    if any(asset.list_index is not None for asset in project.assets):
        return found
    keyword_frames = [frame for frame in frames if frame.id not in taken_frames]
    keyword_assets = [asset for asset in unused if asset.id not in taken_assets]
    hits = {asset.id: _matching_roles(asset, table) for asset in keyword_assets}
    frame_roles = {frame.role_id for frame in keyword_frames}
    by_frame: dict[str, list] = {frame.id: [] for frame in keyword_frames}
    by_asset: dict[str, list] = {asset.id: [] for asset in keyword_assets}
    for frame in keyword_frames:
        for asset in keyword_assets:
            roles = hits[asset.id]
            if frame.role_id in roles and roles == {frame.role_id}:
                by_frame[frame.id].append(asset)
                by_asset[asset.id].append(frame)
    for frame in keyword_frames:
        matched = by_frame[frame.id]
        if len(matched) == 1 and len(by_asset[matched[0].id]) == 1:
            found.append(_make_candidate(STATUS_REVIEW, frame, matched[0], "ファイル名の役割語が一致", 0.4))
            taken_assets.add(matched[0].id)
            taken_frames.add(frame.id)
        elif len(matched) > 1:
            for asset in matched:
                found.append(
                    _make_candidate(STATUS_CONFLICT, frame, asset, "役割語が一致する素材が複数ある", 0.4)
                )
                taken_assets.add(asset.id)
            taken_frames.add(frame.id)
        elif len(matched) == 1:
            found.append(
                _make_candidate(STATUS_CONFLICT, frame, matched[0], "同じ素材が複数の枠の役割語に一致", 0.4)
            )
            taken_assets.add(matched[0].id)
            taken_frames.add(frame.id)
    ambiguous_rows: list[tuple[ImageFrameNode, list]] = []
    for frame in keyword_frames:
        if frame.id in taken_frames:
            continue
        ambiguous = [
            asset
            for asset in keyword_assets
            if asset.id not in taken_assets and frame.role_id in hits[asset.id] and len(hits[asset.id]) > 1
        ]
        if ambiguous:
            ambiguous_rows.append((frame, ambiguous))
    for frame, ambiguous in ambiguous_rows:
        multi_frame = [asset for asset in ambiguous if len(hits[asset.id] & frame_roles) >= 2]
        chosen = multi_frame or ambiguous
        status = STATUS_CONFLICT if multi_frame or len(chosen) > 1 else STATUS_REVIEW
        reason = "ファイル名に複数の役割語がある" if status == STATUS_CONFLICT else "ファイル名にほかの役割語もある"
        confidence = 0.35 if status == STATUS_CONFLICT else 0.6
        for asset in chosen:
            found.append(_make_candidate(status, frame, asset, reason, confidence))
            taken_assets.add(asset.id)
        taken_frames.add(frame.id)
    for frame in keyword_frames:
        for asset in keyword_assets:
            if len(hits[asset.id] & frame_roles) < 2 or frame.role_id not in hits[asset.id]:
                continue
            if any(item.element_id == frame.id and item.asset_id == asset.id for item in found):
                continue
            found.append(_make_candidate(STATUS_CONFLICT, frame, asset, "ファイル名に複数の役割語がある", 0.35))
            taken_assets.add(asset.id)
            taken_frames.add(frame.id)

    partial_frames = [frame for frame in frames if frame.id not in taken_frames]
    partial_assets = [asset for asset in unused if asset.id not in taken_assets]
    for frame in partial_frames:
        partial = [asset for asset in partial_assets if _partial_match(frame, asset)]
        if len(partial) == 1:
            found.append(_make_candidate(STATUS_REVIEW, frame, partial[0], "名前の一部だけ一致", 0.6))
            taken_assets.add(partial[0].id)
            taken_frames.add(frame.id)
        elif len(partial) > 1:
            for asset in partial:
                found.append(
                    _make_candidate(STATUS_CONFLICT, frame, asset, "名前の一部が複数の素材に一致", 0.4)
                )
                taken_assets.add(asset.id)
            taken_frames.add(frame.id)

    order_frames = [frame for frame in frames if frame.id not in taken_frames]
    order_assets = [asset for asset in unused if asset.id not in taken_assets]
    found.extend(_folder_order_candidates(order_frames, order_assets))
    return found


def apply_assignment_candidate(
    project: Project,
    element_id: str,
    asset_id: str,
    synonyms: Mapping[str, Sequence[str]] | None = None,
) -> str:
    """選ばれた候補を1件だけ割り当てる。手動の割当は上書きしない。"""
    current = next(
        (item for item in project.slide.bindings if item.element_id == element_id and item.asset_id),
        None,
    )
    if current is not None:
        if current.asset_id == asset_id:
            raise ValueError("この枠にはすでにその素材が割り当てられています")
        raise ValueError("手動の割当は上書きしません")
    match = next(
        (
            item
            for item in assignment_candidates(project, synonyms)
            if item.element_id == element_id
            and item.asset_id == asset_id
            and item.status in {STATUS_READY, STATUS_REVIEW, STATUS_CONFLICT}
        ),
        None,
    )
    if match is None:
        raise ValueError("この組み合わせは候補にありません")
    from smart_report_builder.roi_edit import assign_registered_asset

    return assign_registered_asset(project, element_id, asset_id)


def apply_ready_candidates(
    project: Project,
    synonyms: Mapping[str, Sequence[str]] | None = None,
) -> list[tuple[str, str]]:
    """確定候補だけを割り当てる。確認推奨と競合は残す。"""
    applied: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    while True:
        ready = [
            item
            for item in assignment_candidates(project, synonyms)
            if item.status == STATUS_READY and (item.element_id, item.asset_id) not in seen
        ]
        if not ready:
            return applied
        chosen = ready[0]
        key = (chosen.element_id, chosen.asset_id)
        seen.add(key)
        apply_assignment_candidate(project, chosen.element_id, chosen.asset_id, synonyms)
        applied.append(key)


def candidate_line(item: AssignmentCandidate) -> str:
    reason = item.reason.replace("\t", " ").replace("\n", " ")
    name = item.asset_name.replace("\t", " ").replace("\n", " ")
    return (
        f"{item.status}\t{item.element_id}\t{item.asset_id}\t{name}\t"
        f"{item.confidence:.2f}\t{item.label}\t{reason}"
    )


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
    "zoom": ("zoom", FitMode.ROI, "拡大画像"),
}
# 以前の役割名。種類は画像にまとめる。
_IMAGE_KIND_ALIASES = {"overall", "comparison"}


def image_frame_kind(frame: ImageFrameNode) -> str:
    """画像枠の種類。拡大か、それ以外の画像か。"""
    if frame.fit_mode == FitMode.ROI:
        return "zoom"
    return "image"


def set_image_frame_kind(project: Project, element_id: str, kind: str) -> str:
    """選択した画像枠の種類を変える。位置と素材の割当は残す。

    拡大にすると、その枠に描いていた ROI は外す。拡大先だった枠を通常の画像に戻すと、
    その枠への連動だけ外し、元画像の上の ROI 矩形は残す。
    """
    if kind in _IMAGE_KIND_ALIASES:
        kind = "image"
    if kind not in _FRAME_KINDS:
        raise ValueError("種類は画像か拡大画像です")
    frame = _find_image_frame(project.content_master.root, element_id)
    if frame is None:
        raise ValueError("画像枠が見つからない")
    if frame.fit_mode not in {FitMode.CONTAIN, FitMode.ROI}:
        raise ValueError("この画像枠の種類は変更できません")
    role_id, fit_mode, _base = _FRAME_KINDS[kind]
    previous = image_frame_kind(frame)
    if previous == kind and frame.role_id == role_id:
        return element_id
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


def set_slide_finding(project: Project, text: str, element_id: str | None = None) -> str:
    """このスライドの文章枠へ見解を書く。マスターの文章は変えない。

    空文字もそのまま保存する。前後の空白や改行は削らない。
    """
    if not isinstance(text, str):
        raise ValueError("見解が文字列ではない")
    node = _finding_node(project, element_id)
    matches = [item for item in project.slide.bindings if item.element_id == node.id]
    if len(matches) > 1:
        raise ValueError("この文章枠の割当が競合しているため変更しません")
    if len(matches) == 1:
        matches[0].text = text
    else:
        project.slide.bindings.append(Binding(element_id=node.id, text=text))
    return node.id


def _finding_node(project: Project, element_id: str | None) -> TextNode:
    texts = [node for node in _walk(project.content_master.root) if isinstance(node, TextNode)]
    if element_id is not None:
        found = next((node for node in texts if node.id == element_id), None)
        if found is None:
            raise ValueError("見解を書く文章枠が見つからない")
        return found
    captions = [node for node in texts if node.role_id == "caption"]
    if captions:
        return captions[0]
    if texts:
        return texts[0]
    raise ValueError("見解を書く文章枠がありません")


def _label_for(status: str) -> str:
    if status == STATUS_READY:
        return LABEL_READY
    if status == STATUS_CONFLICT:
        return LABEL_CONFLICT
    return LABEL_REVIEW


def _make_candidate(status: str, frame: ImageFrameNode, asset, reason: str, confidence: float) -> AssignmentCandidate:
    return AssignmentCandidate(
        status,
        frame.id,
        asset.id,
        asset.display_name,
        reason,
        confidence,
        _label_for(status),
    )


def _synonym_table(synonyms: Mapping[str, Sequence[str]] | None) -> dict[str, tuple[str, ...]]:
    source = DEFAULT_ROLE_SYNONYMS if synonyms is None else synonyms
    table: dict[str, tuple[str, ...]] = {}
    for role_id, words in source.items():
        cleaned = tuple(word.strip() for word in words if word and word.strip())
        if cleaned:
            table[str(role_id)] = cleaned
    return table


def _matching_roles(asset, table: Mapping[str, Sequence[str]]) -> set[str]:
    texts = [asset.display_name, Path(asset.path).stem, Path(asset.path).parent.name]
    found: set[str] = set()
    for role_id, words in table.items():
        if any(_synonym_in_text(text, word) for text in texts for word in words):
            found.add(role_id)
    return found


def _synonym_in_text(text: str, synonym: str) -> bool:
    needle = synonym.casefold()
    if len(needle) < 2:
        return False
    for token in _TOKEN.findall(text):
        folded = token.casefold()
        if folded == needle:
            return True
        if not folded.startswith(needle):
            continue
        rest = folded[len(needle) :]
        if rest and rest[0].isascii() and rest[0].isalpha():
            continue
        return True
    return False


def _folder_order_candidates(frames: list[ImageFrameNode], assets: list) -> list[AssignmentCandidate]:
    if not frames or not assets:
        return []
    groups: dict[str, list] = {}
    for asset in assets:
        key = str(Path(asset.path).parent)
        groups.setdefault(key, []).append(asset)
    several = len(groups) > 1
    status = STATUS_CONFLICT if several else STATUS_REVIEW
    reason = "フォルダが複数あるため、並びを自動では選べない" if several else "同じフォルダのファイル名順"
    confidence = 0.35 if several else 0.5
    found: list[AssignmentCandidate] = []
    for grouped in groups.values():
        ordered = sorted(grouped, key=lambda asset: Path(asset.path).name.casefold())
        for frame, asset in zip(frames, ordered, strict=False):
            found.append(_make_candidate(status, frame, asset, reason, confidence))
    return found


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
