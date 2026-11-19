"""リストの番号から、スライドと画像枠への候補を作る。

候補を計算してもプロジェクトは変えない。採用するまで Binding は書かない。
手動で入っている割当は上書きしない。リストに無い番号は未割当として警告する。
"""

from __future__ import annotations

import json
import re
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
    FrameRef,
    ImageFrameNode,
    LayoutDefinition,
    Project,
    SlideInstance,
    SlideOverride,
    TextNode,
    TextTemplate,
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
    caption: str = ""


@dataclass
class LabelCandidate:
    """採用前のラベル。target は title、文章枠、画像枠のいずれか。"""

    slide_ordinal: int
    target: str
    kind: str
    text: str
    status: str
    reason: str


@dataclass
class OrderedProposal:
    candidates: list[OrderedCandidate] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    labels: list[LabelCandidate] = field(default_factory=list)
    slides_to_add: int = 0

    def to_dict(self) -> dict:
        return {
            "warnings": list(self.warnings),
            "slidesToAdd": self.slides_to_add,
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
                    "caption": item.caption,
                }
                for item in self.candidates
            ],
            "labels": [
                {
                    "slideOrdinal": item.slide_ordinal,
                    "target": item.target,
                    "kind": item.kind,
                    "text": item.text,
                    "status": item.status,
                    "reason": item.reason,
                }
                for item in self.labels
            ],
        }


def set_assignment_rule(project: Project, rule: AssignmentRule) -> None:
    rule = normalize_rule(rule)
    _validate_rule(rule)
    project.content_master.assignment_rule = rule
    for layout in project.layouts:
        layout.content_master.assignment_rule = rule


def expand_assignment(project: Project, rule: AssignmentRule) -> OrderedProposal:
    """ルールをマスターへ保存し、全スライド分の候補を返す。割当は書かない。"""
    set_assignment_rule(project, rule)
    return propose_ordered_assignment(project)


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
        file_name = _blank(record.get("fileName"))
        if file_name:
            asset.file_name = file_name
        elif not asset.file_name:
            asset.file_name = Path(asset.path).name
        note = _blank(record.get("note"))
        if note:
            asset.note = note
        ids.append(asset.id)
    return added, updated, ids


def propose_ordered_assignment(
    project: Project,
    *,
    group: str | None = None,
    task: str | None = None,
    list_name: str | None = None,
) -> OrderedProposal:
    """保存済みルールから候補を返す。リストの絞り込みには依存しない。"""
    del group, task, list_name
    rule = project.content_master.assignment_rule
    if rule is None:
        raise ValueError("割付ルールがありません")
    rule = normalize_rule(rule)
    _validate_rule(rule)
    before = project_to_dict(project)
    proposal = _propose(project, rule)
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
    create_slides: bool = True,
    overwrite_labels: bool = False,
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
    existing_count = len(project.report_slides) or 1
    if not create_slides:
        chosen = [item for item in chosen if item.slide_ordinal < existing_count]
        limited = OrderedProposal(
            candidates=[item for item in proposal.candidates if item.slide_ordinal < existing_count],
            warnings=list(proposal.warnings),
            labels=list(proposal.labels),
        )
        _materialize_slides(project, limited)
    else:
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
    if slide_ordinal is None and frame_index is None:
        _apply_labels(project, proposal, existing_count, create_slides, overwrite_labels, applied)
    return applied


def _apply_labels(
    project: Project,
    proposal: OrderedProposal,
    existing_count: int,
    create_slides: bool,
    overwrite_labels: bool,
    applied: list[tuple[str, str]],
) -> None:
    for label in proposal.labels:
        if not create_slides and label.slide_ordinal >= existing_count:
            continue
        if label.status == "protected" and not overwrite_labels:
            continue
        if label.status not in {"ready", "protected"}:
            continue
        slide, _frames = _slide_frames(project, label.slide_ordinal)
        if label.kind == "title":
            slide.title = label.text
        else:
            _set_binding_text(slide, label.target, label.text)
        applied.append((f"label:{label.target}", label.text))


def _rule_fields(rule: AssignmentRule) -> dict:
    return {
        "range_from": rule.range_from,
        "range_to": rule.range_to,
        "title_template": rule.title_template,
        "text_templates": list(rule.text_templates),
    }


def normalize_rule(rule: AssignmentRule) -> AssignmentRule:
    """古い『1リストのN枚』と『枠ごとの番号』を、枠参照の繰り返しへ読み替える。"""
    if rule.pattern:
        step = rule.step if rule.step >= 1 else max(rule.stride, 1)
        return AssignmentRule(
            mode="pattern",
            offset=rule.offset,
            stride=rule.stride,
            per_slide=max(rule.per_slide, len(rule.pattern)),
            mappings=list(rule.mappings),
            step=step,
            pattern=list(rule.pattern),
            overrides=list(rule.overrides),
            **_rule_fields(rule),
        )
    if rule.mode == "explicit" and rule.mappings:
        pattern = [
            FrameRef(item.element_id, index, "position", "1", item.item_number)
            for index, item in enumerate(rule.mappings)
        ]
    else:
        count = rule.per_slide if rule.per_slide > 0 else 1
        pattern = [
            FrameRef("", index, "position", "1", rule.offset + index) for index in range(count)
        ]
    return AssignmentRule(
        mode="pattern",
        offset=rule.offset,
        stride=rule.stride,
        per_slide=max(rule.per_slide, len(pattern)),
        mappings=list(rule.mappings),
        step=max(rule.stride, 1),
        pattern=pattern,
        overrides=list(rule.overrides),
        **_rule_fields(rule),
    )


def _propose(project: Project, rule: AssignmentRule) -> OrderedProposal:
    existing = _existing_frames(project)
    proposal = OrderedProposal()
    origin = max(rule.range_from, 1) - 1
    end = None if rule.range_to is None else rule.range_to - 1
    ordinal = origin
    while ordinal < _MAX_SLIDES and (end is None or ordinal <= end):
        is_new = ordinal >= len(existing)
        override = next((item for item in rule.overrides if item.slide_ordinal == ordinal), None)
        if is_new:
            slide_id = ""
            count = len(override.frames) if override is not None and override.frames else len(rule.pattern)
            frames: list[ImageFrameNode | None] = [None] * count
        else:
            slide_id, concrete = existing[ordinal]
            frames = list(concrete)
        refs = _refs_for(rule, ordinal, len(frames), origin)
        if end is None and is_new and refs and all(_reference_is_past(project, ref) for ref in refs):
            break
        if not refs and is_new:
            break
        before = len(proposal.candidates)
        for index, ref in enumerate(refs):
            frame = frames[index] if index < len(frames) else None
            element_id = frame.id if frame is not None else ref.element_id
            if not is_new and frame is not None:
                manual = _manual_on_existing(project, slide_id, element_id)
            else:
                manual = None
            if manual is not None:
                proposal.candidates.append(
                    OrderedCandidate(
                        ordinal, slide_id, index, element_id, ref.item_number, manual, "",
                        "protected", "手動割当", "手動の割当は残します",
                    )
                )
                proposal.warnings.append(f"{element_id} の手動割当は残します")
                continue
            resolved = _resolve_ref(project, ref)
            if resolved.status != "ready":
                proposal.warnings.append(resolved.reason)
            elif _already_proposed(proposal, resolved.asset_id or "") or _bound_anywhere(project, resolved.asset_id or ""):
                resolved = _Resolved("conflict", resolved.asset_id, resolved.asset_name, "この素材は別の枠に使われています")
                proposal.warnings.append(resolved.reason)
            proposal.candidates.append(
                OrderedCandidate(
                    ordinal,
                    slide_id,
                    index,
                    element_id,
                    ref.item_number,
                    resolved.asset_id,
                    resolved.asset_name,
                    resolved.status,
                    resolved.label,
                    resolved.reason,
                )
            )
        _plan_labels(project, rule, proposal, ordinal, slide_id, is_new, refs, proposal.candidates[before:])
        ordinal += 1
        if end is not None:
            if ordinal > end:
                break
            continue
        if is_new or ordinal >= len(existing):
            upcoming = _refs_for(rule, ordinal, len(rule.pattern), origin)
            if not upcoming or all(_reference_is_past(project, ref) for ref in upcoming):
                break
    covered = {item.slide_ordinal for item in proposal.candidates}
    if covered and max(covered) + 1 > len(existing):
        proposal.slides_to_add = max(covered) + 1 - len(existing)
        proposal.warnings.append(f"足りないスライドが{proposal.slides_to_add}枚あります。採用するときに追加できます")
    return proposal


@dataclass
class _Resolved:
    status: str
    asset_id: str | None
    asset_name: str
    reason: str

    @property
    def label(self) -> str:
        if self.status == "ready":
            return "確定候補"
        if self.status == "conflict":
            return "競合"
        return "未割当"


@dataclass(frozen=True)
class ImageList:
    group: str
    task: str
    list_name: str
    list_comment: str
    position: int
    task_position: int


def image_lists(project: Project) -> list[ImageList]:
    """リストは group、task、txt 名、Comment= で分け、txt 名順に位置を付ける。"""
    keys: list[tuple[str, str, str, str]] = []
    seen: set[tuple[str, str, str, str]] = set()
    for asset in project.assets:
        if asset.list_index is None:
            continue
        key = (asset.group or "", asset.task or "", asset.list_name or "", asset.list_comment or "")
        if key not in seen:
            seen.add(key)
            keys.append(key)
    keys.sort()
    task_counts: dict[tuple[str, str], int] = {}
    found: list[ImageList] = []
    for key in keys:
        task_key = (key[0], key[1])
        task_counts[task_key] = task_counts.get(task_key, 0) + 1
        found.append(
            ImageList(
                group=key[0],
                task=key[1],
                list_name=key[2],
                list_comment=key[3],
                position=len(found) + 1,
                task_position=task_counts[task_key],
            )
        )
    return found


def matching_lists(project: Project, list_by: str, list_key: str) -> list[ImageList]:
    lists = image_lists(project)
    if list_by == "position":
        return [item for item in lists if str(item.task_position) == str(list_key)]
    if list_by == "name":
        return [item for item in lists if item.list_name == list_key]
    matched = [item for item in lists if item.list_comment and item.list_comment == list_key]
    if matched:
        return matched
    return [item for item in lists if not item.list_comment and item.list_name == list_key]


def _assets_in_list(project: Project, image_list: ImageList, number: int) -> list[Asset]:
    return [
        asset
        for asset in project.assets
        if asset.list_index == number
        and (asset.group or "") == image_list.group
        and (asset.task or "") == image_list.task
        and (asset.list_name or "") == image_list.list_name
        and (asset.list_comment or "") == image_list.list_comment
    ]


def _list_label(image_list: ImageList) -> str:
    return image_list.list_comment or image_list.list_name or f"{image_list.task_position}番目のリスト"


def _resolve_ref(project: Project, ref: FrameRef) -> _Resolved:
    lists = matching_lists(project, ref.list_by, ref.list_key)
    label = ref.list_key or "リスト"
    if len(lists) == 0:
        return _Resolved("missing", None, "", f"{label} の{ref.item_number}番がありません")
    if len(lists) > 1:
        return _Resolved("conflict", None, "", f"同じ指定のリストが複数あります: {label}")
    found = _assets_in_list(project, lists[0], ref.item_number)
    list_label = _list_label(lists[0])
    if len(found) == 0:
        return _Resolved("missing", None, "", f"{list_label} に{ref.item_number}番がありません")
    if len(found) > 1:
        return _Resolved("conflict", None, "", f"{list_label} の{ref.item_number}番が複数あります")
    asset = found[0]
    return _Resolved("ready", asset.id, asset.display_name, f"{list_label} の{ref.item_number}番")


def _reference_is_past(project: Project, ref: FrameRef) -> bool:
    lists = matching_lists(project, ref.list_by, ref.list_key)
    if len(lists) != 1:
        return True
    numbers = [
        asset.list_index
        for asset in project.assets
        if asset.list_index is not None and _same_list(asset, lists[0])
    ]
    if not numbers:
        return True
    return ref.item_number > max(numbers)


def _same_list(asset: Asset, image_list: ImageList) -> bool:
    return (
        (asset.group or "") == image_list.group
        and (asset.task or "") == image_list.task
        and (asset.list_name or "") == image_list.list_name
        and (asset.list_comment or "") == image_list.list_comment
    )


def _refs_for(rule: AssignmentRule, ordinal: int, frame_count: int, origin: int) -> list[FrameRef]:
    override = next((item for item in rule.overrides if item.slide_ordinal == ordinal), None)
    if override is not None:
        return list(override.frames[:frame_count])
    refs: list[FrameRef] = []
    for index, ref in enumerate(rule.pattern[:frame_count]):
        refs.append(
            FrameRef(
                ref.element_id,
                ref.frame_index,
                ref.list_by,
                ref.list_key,
                ref.item_number + (ordinal - origin) * rule.step,
                ref.label_template,
            )
        )
    return refs


_LABEL_TOKEN = re.compile(r"\{([A-Za-z0-9_]+)\}")
LABEL_VARIABLES = (
    "comment",
    "note",
    "txt",
    "file",
    "index",
    "n",
    "slide",
    "group",
    "task",
)


@dataclass
class RenderedLabel:
    text: str
    missing: list[str]


def render_label(
    template: str,
    numbered: dict[int, Asset | None],
    slide_number: int,
    *,
    focus: int | None = None,
) -> RenderedLabel:
    """自由な文と変数を混ぜる。値が無い変数は空にし、名前を missing に入れる。"""
    if not template:
        return RenderedLabel("", [])
    values = {"slide": str(slide_number)}

    def fill(asset: Asset | None, suffix: str) -> None:
        file_name = ""
        comment = ""
        txt = ""
        index = ""
        note = ""
        group = ""
        task = ""
        if asset is not None:
            file_name = asset.file_name or Path(asset.path).name
            comment = asset.list_comment or ""
            txt = asset.list_name or ""
            index = "" if asset.list_index is None else str(asset.list_index)
            note = asset.note or ""
            group = asset.group or ""
            task = asset.task or ""
        values[f"comment{suffix}"] = comment
        values[f"note{suffix}"] = note
        values[f"txt{suffix}"] = txt
        values[f"file{suffix}"] = file_name
        values[f"index{suffix}"] = index
        values[f"n{suffix}"] = index
        values[f"group{suffix}"] = group
        values[f"task{suffix}"] = task

    fill(numbered.get(0 if focus is None else focus), "")
    for index, asset in numbered.items():
        fill(asset, str(index + 1))
    missing: list[str] = []

    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        if not values.get(key):
            missing.append(key)
            return ""
        return values[key]

    return RenderedLabel(_LABEL_TOKEN.sub(replace, template), missing)


def _plan_labels(
    project: Project,
    rule: AssignmentRule,
    proposal: OrderedProposal,
    ordinal: int,
    slide_id: str,
    is_new: bool,
    refs: list[FrameRef],
    made: list[OrderedCandidate],
) -> None:
    if not rule.title_template and not rule.text_templates and not any(ref.label_template for ref in refs):
        return
    numbered: dict[int, Asset | None] = {}
    for item in made:
        numbered[item.frame_index] = _asset_by_id(project, item.asset_id)
    slide_number = ordinal + 1
    slide = None if is_new else _slide_by_ordinal(project, ordinal)
    page_title = project.design_master.page_title.strip()

    def remember(kind: str, target: str, rendered: RenderedLabel, manual: bool, master_warning: str) -> None:
        proposal.labels.append(
            LabelCandidate(
                ordinal,
                target,
                kind,
                rendered.text,
                "protected" if manual else "ready",
                master_warning if manual else rendered.text,
            )
        )
        if manual:
            proposal.warnings.append(f"スライド{slide_number} の{master_warning}")
        if rendered.missing:
            names = "、".join(f"{{{name}}}" for name in rendered.missing)
            proposal.warnings.append(f"スライド{slide_number} の {names} は空です")

    if rule.title_template:
        rendered = render_label(rule.title_template, numbered, slide_number)
        current = "" if slide is None else slide.title.strip()
        manual = bool(current) and current != rendered.text and current != page_title
        remember("title", "title", rendered, manual, "手入力のタイトルは残します")
    nodes = _text_nodes(project, ordinal, is_new)
    for template in rule.text_templates:
        node = _text_node(nodes, template.element_id)
        if node is None:
            proposal.warnings.append("ラベルを書く文章枠がありません")
            continue
        rendered = render_label(template.template, numbered, slide_number)
        current = None if slide is None else _binding_text(slide, node.id)
        manual = _text_is_manual(current, node.text, rendered.text)
        remember("text", node.id, rendered, manual, "手入力のラベルは残します")
    for ref, item in zip(refs, made, strict=False):
        if not ref.label_template:
            continue
        rendered = render_label(ref.label_template, numbered, slide_number, focus=item.frame_index)
        current = None if slide is None else _binding_text(slide, item.element_id)
        manual = _text_is_manual(current, None, rendered.text)
        remember("frame", item.element_id, rendered, manual, "手入力のラベルは残します")
        item.caption = rendered.text


def _text_is_manual(current: str | None, master: str | None, generated: str) -> bool:
    if current is None:
        return False
    if current == generated:
        return False
    if master is not None and current == master:
        return False
    return True


def _binding_text(slide: SlideInstance, element_id: str) -> str | None:
    matches = [item for item in slide.bindings if item.element_id == element_id]
    if len(matches) != 1:
        return None
    return matches[0].text


def _set_binding_text(slide: SlideInstance, element_id: str, text: str) -> None:
    matches = [item for item in slide.bindings if item.element_id == element_id]
    if len(matches) > 1:
        return
    if len(matches) == 1:
        matches[0].text = text
        return
    slide.bindings.append(Binding(element_id=element_id, text=text))


def _asset_by_id(project: Project, asset_id: str | None) -> Asset | None:
    if not asset_id:
        return None
    return next((item for item in project.assets if item.id == asset_id), None)


def _slide_by_ordinal(project: Project, ordinal: int) -> SlideInstance | None:
    if project.report_slides:
        if ordinal >= len(project.report_slides):
            return None
        return project.report_slides[ordinal].slide
    if ordinal == 0:
        return project.slide
    return None


def _text_nodes(project: Project, ordinal: int, is_new: bool) -> list[TextNode]:
    master = project.content_master
    if not is_new and project.report_slides and ordinal < len(project.report_slides):
        layout_id = project.report_slides[ordinal].layout_id
        layout = next((item for item in project.layouts if item.id == layout_id), None)
        if layout is not None:
            master = layout.content_master
    return [node for node in _walk_nodes(master.root) if isinstance(node, TextNode)]


def _text_node(nodes: list[TextNode], element_id: str) -> TextNode | None:
    if element_id:
        return next((node for node in nodes if node.id == element_id), None)
    captions = [node for node in nodes if node.role_id == "caption"]
    if captions:
        return captions[0]
    return nodes[0] if nodes else None


def _walk_nodes(node):
    yield node
    for child in getattr(node, "children", []) or []:
        yield from _walk_nodes(child)


def _materialize_slides(project: Project, proposal: OrderedProposal) -> None:
    from smart_report_builder.practical import add_image_frame
    from smart_report_builder.roi_edit import _append_slide, _ensure_deck

    needed = 0
    for item in proposal.candidates:
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
    if rule.step < 1:
        raise ValueError("次のスライドへ進む数は1以上です")
    if rule.range_from < 1:
        raise ValueError("開始スライドは1以上です")
    if rule.range_to is not None and rule.range_to < rule.range_from:
        raise ValueError("終了スライドは開始スライド以降です")
    if not rule.pattern:
        raise ValueError("枠の参照がありません")
    if len(rule.pattern) > 8:
        raise ValueError("1枚あたりの画像枠は8までです")
    for ref in [*rule.pattern, *[ref for item in rule.overrides for ref in item.frames]]:
        if ref.item_number < 1:
            raise ValueError("リストの番号は1から始まります")
        if ref.list_by not in {"comment", "name", "position"}:
            raise ValueError("リストの指定が違います")
        if not str(ref.list_key):
            raise ValueError("リストの指定が空です")


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
    if payload.get("pattern"):
        pattern = [
            FrameRef(
                element_id=str(item.get("elementId") or ""),
                frame_index=int(item.get("frameIndex", index)),
                list_by=str(item.get("listBy") or "comment"),
                list_key=str(item.get("listKey") or ""),
                item_number=int(item["itemNumber"]),
                label_template=str(item.get("labelTemplate") or ""),
            )
            for index, item in enumerate(payload["pattern"])
        ]
        range_to = payload.get("rangeTo")
        overrides = [
            SlideOverride(
                slide_ordinal=int(item.get("slideOrdinal", 0)),
                frames=[
                    FrameRef(
                        element_id=str(ref.get("elementId") or ""),
                        frame_index=int(ref.get("frameIndex", index)),
                        list_by=str(ref.get("listBy") or "comment"),
                        list_key=str(ref.get("listKey") or ""),
                        item_number=int(ref["itemNumber"]),
                    )
                    for index, ref in enumerate(item.get("frames") or [])
                ],
            )
            for item in payload.get("overrides") or []
        ]
        return normalize_rule(
            AssignmentRule(
                mode="pattern",
                step=int(payload.get("step", 1)),
                per_slide=len(pattern),
                pattern=pattern,
                overrides=overrides,
                range_from=int(payload.get("rangeFrom", 1)),
                range_to=None if range_to in (None, "") else int(range_to),
                title_template=str(payload.get("titleTemplate") or ""),
                text_templates=[
                    TextTemplate(
                        element_id=str(item.get("elementId") or ""),
                        template=str(item.get("template") or ""),
                    )
                    for item in payload.get("textTemplates") or []
                    if isinstance(item, dict) and str(item.get("template") or "")
                ],
            )
        )
    mappings = [
        FrameMapping(element_id=str(item["elementId"]), item_number=int(item["itemNumber"]))
        for item in payload.get("mappings", [])
    ]
    return normalize_rule(
        AssignmentRule(
            mode=str(payload.get("mode") or "sequential"),
            offset=int(payload.get("offset", 1)),
            stride=int(payload.get("stride", payload.get("perSlide", 1))),
            per_slide=int(payload.get("perSlide", 2)),
            mappings=mappings,
        )
    )
