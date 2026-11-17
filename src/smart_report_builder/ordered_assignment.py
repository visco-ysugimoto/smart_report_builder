"""リストの番号から、スライドと画像枠への候補を作る。

候補を計算してもプロジェクトは変えない。採用するまで Binding は書かない。
手動で入っている割当は上書きしない。リストに無い番号は未割当として警告する。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from smart_report_builder.models import (
    SCHEMA_VERSION,
    Asset,
    AssignmentRule,
    Binding,
    ContentMaster,
    FitMode,
    FrameMapping,
    ImageFrameNode,
    LayoutDefinition,
    Project,
    SlideInstance,
    project_from_dict,
    project_to_dict,
)
from smart_report_builder.project_factory import create_report

SOURCE_FOLDER = "folder"
SOURCE_TASK_FILE = "task-file"
_SOURCES = {SOURCE_FOLDER, SOURCE_TASK_FILE}
_MAX_SLIDES = 40


@dataclass
class OrderedCandidate:
    slide_ordinal: int
    slide_id: str
    frame_index: int
    element_id: str
    item_number: int
    asset_id: str | None
    asset_name: str
    status: str
    label: str
    reason: str


@dataclass
class OrderedProposal:
    candidates: list[OrderedCandidate] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "warnings": list(self.warnings),
            "candidates": [
                {
                    "slideOrdinal": item.slide_ordinal,
                    "slideId": item.slide_id,
                    "frameIndex": item.frame_index,
                    "elementId": item.element_id,
                    "itemNumber": item.item_number,
                    "assetId": item.asset_id,
                    "assetName": item.asset_name,
                    "status": item.status,
                    "label": item.label,
                    "reason": item.reason,
                }
                for item in self.candidates
            ],
        }


def set_assignment_rule(project: Project, rule: AssignmentRule) -> None:
    _validate_rule(rule)
    project.content_master.assignment_rule = rule
    for layout in project.layouts:
        layout.content_master.assignment_rule = rule


def register_ordered_assets(project: Project, records: list[dict]) -> tuple[int, int, list[str]]:
    """一覧の画像を素材として足す。枠へは割り当てない。

    同じパスが既にあれば、並びの情報だけを更新する。戻り値は追加件数、更新件数、素材 ID。
    """
    if project.schema_version != SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {project.schema_version}")
    added = 0
    updated = 0
    ids: list[str] = []
    known = {}
    for asset in project.assets:
        try:
            known[str(Path(asset.path).resolve())] = asset
        except OSError:
            continue
    for record in records:
        path = Path(str(record.get("path", "")))
        if not path.is_file():
            raise ValueError("画像ファイルが見つからない")
        source = str(record.get("source") or "")
        if source not in _SOURCES:
            raise ValueError("素材の出所は folder か task-file です")
        index = record.get("listIndex")
        if index is not None:
            index = int(index)
            if index < 1:
                raise ValueError("リストの番号は1から始まります")
        resolved = str(path.resolve())
        asset = known.get(resolved)
        if asset is None:
            width, height = _read_image_size(path)
            asset = Asset(
                id=_next_asset_id(project),
                path=resolved,
                width_px=width,
                height_px=height,
                display_name=path.stem or path.name,
            )
            project.assets.append(asset)
            known[resolved] = asset
            added += 1
        else:
            updated += 1
        asset.source = source
        asset.group = _blank(record.get("group"))
        asset.task = _blank(record.get("task"))
        asset.list_name = _blank(record.get("listName"))
        asset.list_comment = _blank(record.get("listComment"))
        asset.list_index = index
        ids.append(asset.id)
    return added, updated, ids


def propose_ordered_assignment(
    project: Project,
    *,
    group: str | None = None,
    task: str | None = None,
    list_name: str | None = None,
) -> OrderedProposal:
    """ルールとリストから候補を返す。プロジェクトは変えない。"""
    rule = project.content_master.assignment_rule
    if rule is None:
        raise ValueError("割付ルールがありません")
    _validate_rule(rule)
    before = project_to_dict(project)
    proposal = _propose(project, rule, group=group, task=task, list_name=list_name)
    if project_to_dict(project) != before:
        raise RuntimeError("候補の計算がプロジェクトを変えた")
    return proposal


def accept_ordered_assignment(
    project: Project,
    *,
    group: str | None = None,
    task: str | None = None,
    list_name: str | None = None,
    slide_ordinal: int | None = None,
    frame_index: int | None = None,
) -> list[tuple[str, str]]:
    """候補を採用する。slide と frame を指定したときはその1件だけ。"""
    proposal = propose_ordered_assignment(project, group=group, task=task, list_name=list_name)
    chosen = [
        item
        for item in proposal.candidates
        if item.status == "ready"
        and (slide_ordinal is None or item.slide_ordinal == slide_ordinal)
        and (frame_index is None or item.frame_index == frame_index)
    ]
    if slide_ordinal is not None and not any(
        item.slide_ordinal == slide_ordinal and (frame_index is None or item.frame_index == frame_index)
        for item in proposal.candidates
    ):
        raise ValueError("採用できる候補がありません")
    _materialize_slides(project, proposal)
    applied: list[tuple[str, str]] = []
    for item in chosen:
        slide, frames = _slide_frames(project, item.slide_ordinal)
        if item.frame_index >= len(frames):
            continue
        frame = frames[item.frame_index]
        if _manual_asset(slide, frame.id) is not None:
            continue
        if item.asset_id is None:
            continue
        if _asset_is_bound(project, item.asset_id, frame.id):
            continue
        _bind(slide, frame.id, item.asset_id)
        if project.slide is slide:
            pass
        applied.append((frame.id, item.asset_id))
    return applied


def _propose(
    project: Project,
    rule: AssignmentRule,
    *,
    group: str | None,
    task: str | None,
    list_name: str | None,
) -> OrderedProposal:
    assets = _listed_assets(project, group=group, task=task, list_name=list_name)
    by_number: dict[int, list[Asset]] = {}
    for asset in assets:
        if asset.list_index is None:
            continue
        by_number.setdefault(asset.list_index, []).append(asset)
    max_item = max(by_number, default=0)
    existing = _existing_frames(project)
    proposal = OrderedProposal()
    for number, found in by_number.items():
        if len(found) > 1:
            names = "、".join(item.display_name for item in found)
            proposal.warnings.append(f"リストの{number}番が複数あるため、自動では選びません: {names}")
    ordinal = 0
    while ordinal < _MAX_SLIDES:
        if ordinal < len(existing):
            slide_id, frames = existing[ordinal]
        else:
            slide_id, frames = "", [None] * rule.per_slide
        numbers = [
            _item_number(rule, ordinal, index, "" if frame is None else frame.id)
            for index, frame in enumerate(frames)
        ]
        usable = [number for number in numbers if number is not None]
        if not usable or min(usable) > max(max_item, rule.offset):
            if ordinal >= len(existing):
                break
        if usable and min(usable) > max_item and ordinal >= len(existing):
            break
        if ordinal >= len(existing) and usable and min(usable) > max_item:
            break
        for index, number in enumerate(numbers):
            if number is None:
                continue
            frame = frames[index]
            element_id = "" if frame is None else frame.id
            manual = None
            if ordinal < len(existing):
                manual = _manual_on_existing(project, slide_id, element_id)
            if manual is not None:
                proposal.candidates.append(
                    OrderedCandidate(
                        ordinal, slide_id, index, element_id, number, manual, "",
                        "protected", "手動割当", "手動の割当は残します",
                    )
                )
                proposal.warnings.append(f"{element_id} の手動割当は残します")
                continue
            found = by_number.get(number, [])
            if len(found) == 0:
                reason = f"リストに{number}番がありません"
                proposal.candidates.append(
                    OrderedCandidate(
                        ordinal, slide_id, index, element_id, number, None, "",
                        "missing", "未割当", reason,
                    )
                )
                proposal.warnings.append(reason)
                continue
            if len(found) > 1:
                reason = f"リストの{number}番が複数あります"
                proposal.candidates.append(
                    OrderedCandidate(
                        ordinal, slide_id, index, element_id, number, None, "",
                        "conflict", "競合", reason,
                    )
                )
                proposal.warnings.append(reason)
                continue
            asset = found[0]
            if _already_proposed(proposal, asset.id) or _bound_anywhere(project, asset.id):
                proposal.candidates.append(
                    OrderedCandidate(
                        ordinal, slide_id, index, element_id, number, asset.id, asset.display_name,
                        "conflict", "競合", "この素材は別の枠に使われています",
                    )
                )
                continue
            proposal.candidates.append(
                OrderedCandidate(
                    ordinal, slide_id, index, element_id, number, asset.id, asset.display_name,
                    "ready", "確定候補", f"リストの{number}番",
                )
            )
        ordinal += 1
        if ordinal >= len(existing):
            upcoming = [
                _item_number(rule, ordinal, index, "")
                for index in range(rule.per_slide)
            ]
            upcoming = [number for number in upcoming if number is not None]
            if not upcoming or min(upcoming) > max_item:
                break
    return proposal


def _item_number(rule: AssignmentRule, slide_index: int, frame_index: int, element_id: str) -> int | None:
    if rule.mode == "sequential":
        return rule.offset + slide_index * rule.stride + frame_index
    chosen = None
    for mapping in rule.mappings:
        if element_id and mapping.element_id == element_id:
            chosen = mapping.item_number
            break
    if chosen is None and frame_index < len(rule.mappings):
        chosen = rule.mappings[frame_index].item_number
    if chosen is None:
        return None
    return chosen + slide_index * rule.stride


def _materialize_slides(project: Project, proposal: OrderedProposal) -> None:
    from smart_report_builder.practical import add_image_frame
    from smart_report_builder.roi_edit import _append_slide, _ensure_deck

    needed = 0
    for item in proposal.candidates:
        if item.status == "ready":
            needed = max(needed, item.slide_ordinal + 1)
    if needed <= 1 and not project.report_slides:
        _ensure_slide_frames(project, 0, _frames_needed(proposal, 0), add_image_frame)
        return
    _ensure_deck(project)
    active = project.active_slide_id
    master = project.content_master
    slide = project.slide
    while len(project.report_slides) < needed:
        count = _frames_needed(proposal, len(project.report_slides))
        layout = _layout_with_frames(project, count, add_image_frame)
        _append_slide(project, layout)
    for ordinal in range(min(needed, len(project.report_slides))):
        _ensure_slide_frames(project, ordinal, _frames_needed(proposal, ordinal), add_image_frame)
    project.content_master = master
    project.slide = slide
    project.active_slide_id = active


def _frames_needed(proposal: OrderedProposal, ordinal: int) -> int:
    indexes = [item.frame_index for item in proposal.candidates if item.slide_ordinal == ordinal]
    if not indexes:
        return 0
    return max(indexes) + 1


def _layout_with_frames(project: Project, count: int, add_image_frame) -> LayoutDefinition:
    from smart_report_builder.roi_edit import _next_numbered_id

    for layout in project.layouts:
        if len(_contain(layout.content_master)) == count and count > 0:
            return layout
    cloned = _clone_master(project.content_master)
    cloned.id = _next_numbered_id("master-", {item.content_master.id for item in project.layouts})
    layout = LayoutDefinition(
        id=_next_numbered_id("layout-", {item.id for item in project.layouts}),
        name=cloned.name,
        content_master=cloned,
    )
    project.layouts.append(layout)
    previous_master = project.content_master
    project.content_master = cloned
    while len(_contain(cloned)) < count:
        add_image_frame(project)
    project.content_master = previous_master
    return layout


def _ensure_slide_frames(project: Project, ordinal: int, count: int, add_image_frame) -> None:
    from smart_report_builder.roi_edit import _ensure_deck

    if count <= 0:
        return
    if not project.report_slides:
        _ensure_deck(project)
    item = project.report_slides[ordinal]
    layout = next(layout for layout in project.layouts if layout.id == item.layout_id)
    if len(_contain(layout.content_master)) >= count:
        return
    if any(other.layout_id == layout.id and other.id != item.id for other in project.report_slides):
        layout = _layout_with_frames(project, count, add_image_frame)
        item.layout_id = layout.id
        item.slide.content_master_id = layout.content_master.id
        return
    previous = project.content_master
    project.content_master = layout.content_master
    while len(_contain(layout.content_master)) < count:
        add_image_frame(project)
    project.content_master = previous


def _clone_master(master: ContentMaster) -> ContentMaster:
    payload = project_to_dict(
        Project(
            design_master=create_report().design_master,
            content_master=master,
            assets=[],
            slide=SlideInstance(id="temp", content_master_id=master.id),
        )
    )
    cloned = project_from_dict(payload).content_master
    return cloned


def _slide_frames(project: Project, ordinal: int):
    from smart_report_builder.roi_edit import _ensure_deck

    if not project.report_slides:
        _ensure_deck(project)
    item = project.report_slides[ordinal]
    layout = next(layout for layout in project.layouts if layout.id == item.layout_id)
    return item.slide, _contain(layout.content_master)


def _existing_frames(project: Project) -> list[tuple[str, list[ImageFrameNode]]]:
    if project.report_slides:
        found = []
        for item in project.report_slides:
            layout = next(layout for layout in project.layouts if layout.id == item.layout_id)
            found.append((item.id, _contain(layout.content_master)))
        return found
    return [(project.slide.id, _contain(project.content_master))]


def _manual_on_existing(project: Project, slide_id: str, element_id: str) -> str | None:
    if project.report_slides:
        item = next((slide for slide in project.report_slides if slide.id == slide_id), None)
        slide = project.slide if item is None else item.slide
    else:
        slide = project.slide
    return _manual_asset(slide, element_id)


def _manual_asset(slide: SlideInstance, element_id: str) -> str | None:
    matches = [item.asset_id for item in slide.bindings if item.element_id == element_id and item.asset_id]
    if len(matches) == 1:
        return matches[0]
    return None


def _bound_anywhere(project: Project, asset_id: str) -> bool:
    slides = [item.slide for item in project.report_slides] or [project.slide]
    return any(binding.asset_id == asset_id for slide in slides for binding in slide.bindings)


def _already_proposed(proposal: OrderedProposal, asset_id: str) -> bool:
    return any(item.asset_id == asset_id and item.status == "ready" for item in proposal.candidates)


def _asset_is_bound(project: Project, asset_id: str, element_id: str) -> bool:
    return _bound_anywhere(project, asset_id)


def _bind(slide: SlideInstance, element_id: str, asset_id: str) -> None:
    matches = [item for item in slide.bindings if item.element_id == element_id]
    if len(matches) > 1:
        return
    if len(matches) == 1:
        if matches[0].asset_id:
            return
        matches[0].asset_id = asset_id
        return
    slide.bindings.append(Binding(element_id=element_id, asset_id=asset_id))


def _listed_assets(
    project: Project,
    *,
    group: str | None,
    task: str | None,
    list_name: str | None,
) -> list[Asset]:
    found = []
    for asset in project.assets:
        if asset.list_index is None:
            continue
        if group is not None and (asset.group or "") != group:
            continue
        if task is not None and (asset.task or "") != task:
            continue
        if list_name is not None and (asset.list_name or "") != list_name:
            continue
        found.append(asset)
    return found


def _contain(master: ContentMaster) -> list[ImageFrameNode]:
    return [frame for frame in _frames(master.root) if frame.fit_mode == FitMode.CONTAIN]


def _frames(node) -> list[ImageFrameNode]:
    if isinstance(node, ImageFrameNode):
        return [node]
    found: list[ImageFrameNode] = []
    for child in getattr(node, "children", []) or []:
        found.extend(_frames(child))
    return found


def _validate_rule(rule: AssignmentRule) -> None:
    if rule.mode not in {"explicit", "sequential"}:
        raise ValueError("割付は番号の指定か、枚数ごとの順送りです")
    if rule.offset < 1 or rule.stride < 1 or rule.per_slide < 1:
        raise ValueError("開始番号、送り、1枚あたりの枚数は1以上です")
    if rule.per_slide > 8:
        raise ValueError("1枚あたりの画像枠は8までです")
    if rule.mode == "explicit" and not rule.mappings:
        raise ValueError("枠ごとの番号がありません")
    for mapping in rule.mappings:
        if mapping.item_number < 1:
            raise ValueError("リストの番号は1から始まります")


def _blank(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _next_asset_id(project: Project) -> str:
    used = {item.id for item in project.assets}
    number = 1
    while f"asset-{number}" in used:
        number += 1
    return f"asset-{number}"


def _read_image_size(path: Path) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            width, height = image.size
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError("画像として読めません") from exc
    if width <= 0 or height <= 0:
        raise ValueError("画像のピクセル寸法が不正")
    return width, height


def proposal_json(proposal: OrderedProposal) -> str:
    return json.dumps(proposal.to_dict(), ensure_ascii=False)


def rule_from_payload(payload: dict) -> AssignmentRule:
    mappings = [
        FrameMapping(element_id=str(item["elementId"]), item_number=int(item["itemNumber"]))
        for item in payload.get("mappings", [])
    ]
    return AssignmentRule(
        mode=str(payload["mode"]),
        offset=int(payload.get("offset", 1)),
        stride=int(payload.get("stride", payload.get("perSlide", 1))),
        per_slide=int(payload.get("perSlide", 2)),
        mappings=mappings,
    )
