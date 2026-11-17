import json
from pathlib import Path

import pytest
from PIL import Image

from smart_report_builder.models import (
    SCHEMA_VERSION,
    AssignmentRule,
    Binding,
    FrameMapping,
    FrameRef,
    SlideOverride,
    project_from_dict,
    project_to_dict,
)
from smart_report_builder.ordered_assignment import (
    accept_ordered_assignment,
    expand_assignment,
    propose_ordered_assignment,
    register_ordered_assets,
    set_assignment_rule,
)
from smart_report_builder.practical import assignment_candidates
from smart_report_builder.project_factory import create_report
from smart_report_builder.project_store import load_project, save_project
from smart_report_builder.roi_edit import add_layout


def _png(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (8, 8), (10, 20, 30)).save(path, format="PNG")
    return path


def _record(path: Path, index: int, **extra) -> dict:
    payload = {
        "path": str(path),
        "source": "task-file",
        "group": "g01",
        "task": "03",
        "listName": "cap",
        "listComment": "外観",
        "listIndex": index,
    }
    payload.update(extra)
    return payload


def _load_list(project, directory: Path, count: int) -> None:
    records = [_record(_png(directory / f"img_{index}.png"), index) for index in range(1, count + 1)]
    register_ordered_assets(project, records)


def _rule(**kwargs) -> AssignmentRule:
    values = {"mode": "sequential", "offset": 1, "stride": 2, "per_slide": 2}
    values.update(kwargs)
    return AssignmentRule(**values)


def test_old_project_loads_and_saves_as_the_new_schema(tmp_path: Path):
    project = create_report()
    path = tmp_path / "project.json"
    save_project(project, path)
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["schemaVersion"] = 1
    payload["designMaster"]["schemaVersion"] = 1
    payload["contentMaster"]["schemaVersion"] = 1
    path.write_text(json.dumps(payload), encoding="utf-8")
    loaded = load_project(path)
    assert loaded.schema_version == SCHEMA_VERSION
    assert loaded.assets == []
    assert loaded.content_master.assignment_rule is None
    save_project(loaded, path)
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert stored["schemaVersion"] == 2
    with pytest.raises(ValueError, match="schemaVersion"):
        project_from_dict({"schemaVersion": 999, "designMaster": {}, "contentMaster": {}, "assets": [], "slide": {}})


def test_register_keeps_order_and_does_not_assign_or_duplicate(tmp_path: Path):
    project = create_report()
    image = _png(tmp_path / "cam1.png")
    added, updated, ids = register_ordered_assets(project, [_record(image, 2, listComment="外観検査")])
    assert (added, updated, ids) == (1, 0, [project.assets[0].id])
    asset = project.assets[0]
    assert project.slide.bindings == []
    assert (asset.group, asset.task, asset.list_name, asset.list_comment, asset.list_index, asset.source) == (
        "g01",
        "03",
        "cap",
        "外観検査",
        2,
        "task-file",
    )
    again, changed, ids = register_ordered_assets(project, [_record(image, 2, listComment="外観検査")])
    assert (again, changed, len(project.assets), ids) == (0, 1, 1, [project.assets[0].id])
    restored = project_from_dict(project_to_dict(project))
    assert restored.assets[0].list_index == 2
    assert assignment_candidates(project) == []


def test_three_per_slide_keeps_the_remainder_as_unassigned(tmp_path: Path):
    project = create_report(image_count=3)
    _load_list(project, tmp_path, 7)
    set_assignment_rule(project, _rule(stride=3, per_slide=3))
    before = project_to_dict(project)
    proposal = propose_ordered_assignment(project, group="g01", task="03", list_name="cap")
    assert project_to_dict(project) == before
    ready = [(item.slide_ordinal, item.frame_index, item.item_number) for item in proposal.candidates if item.status == "ready"]
    assert ready == [(0, 0, 1), (0, 1, 2), (0, 2, 3), (1, 0, 4), (1, 1, 5), (1, 2, 6), (2, 0, 7)]
    missing = [item.item_number for item in proposal.candidates if item.status == "missing"]
    assert missing == [8, 9]
    assert any("8番がありません" in warning for warning in proposal.warnings)
    assert accept_ordered_assignment(project, group="g01", task="03", list_name="cap")
    numbers = sorted(asset.list_index for asset in project.assets if _asset_is_bound(project, asset.id))
    assert numbers == [1, 2, 3, 4, 5, 6, 7]


def test_explicit_mapping_past_the_list_does_not_raise(tmp_path: Path):
    project = create_report(image_count=2)
    _load_list(project, tmp_path, 2)
    set_assignment_rule(
        project,
        _rule(
            mode="explicit",
            stride=4,
            per_slide=2,
            mappings=[
                FrameMapping("frame-overall", 1),
                FrameMapping("frame-compare", 4),
            ],
        ),
    )
    proposal = propose_ordered_assignment(project, group="g01", task="03", list_name="cap")
    by_frame = {item.element_id: item for item in proposal.candidates if item.slide_ordinal == 0}
    assert by_frame["frame-overall"].status == "ready"
    assert by_frame["frame-overall"].item_number == 1
    assert by_frame["frame-compare"].status == "missing"
    assert by_frame["frame-compare"].label == "未割当"
    assert all(item.slide_ordinal == 0 for item in proposal.candidates)
    applied = accept_ordered_assignment(project, group="g01", task="03", list_name="cap")
    assert applied == [("frame-overall", project.assets[0].id)]
    assert len(project.slide.bindings) == 1


def test_mixed_frame_counts_follow_offset_and_stride(tmp_path: Path):
    project = create_report(image_count=2)
    _load_list(project, tmp_path, 6)
    add_layout(project, image_count=3, arrangement="horizontal", template="images")
    set_assignment_rule(project, _rule(offset=1, stride=3, per_slide=3))
    proposal = propose_ordered_assignment(project, group="g01", task="03", list_name="cap")
    ready = [(item.slide_ordinal, item.item_number) for item in proposal.candidates if item.status == "ready"]
    assert ready[:2] == [(0, 1), (0, 2)]
    assert ready[2:5] == [(1, 4), (1, 5), (1, 6)]
    assert 3 not in {item.item_number for item in proposal.candidates if item.status == "ready"}


def test_manual_assignment_is_kept_and_one_candidate_can_be_accepted(tmp_path: Path):
    project = create_report(image_count=2)
    _load_list(project, tmp_path, 4)
    kept = project.assets[0]
    project.slide.bindings = [Binding(element_id="frame-overall", asset_id=kept.id)]
    set_assignment_rule(project, _rule(stride=2, per_slide=2))
    proposal = propose_ordered_assignment(project, group="g01", task="03", list_name="cap")
    protected = next(item for item in proposal.candidates if item.element_id == "frame-overall" and item.slide_ordinal == 0)
    assert protected.status == "protected"
    before = project_to_dict(project)
    propose_ordered_assignment(project, group="g01", task="03", list_name="cap")
    assert project_to_dict(project) == before
    accept_ordered_assignment(project, group="g01", task="03", list_name="cap", slide_ordinal=0, frame_index=0)
    assert project.slide.bindings[0].asset_id == kept.id
    accept_ordered_assignment(project, group="g01", task="03", list_name="cap", slide_ordinal=0, frame_index=1)
    assert ("frame-compare", project.assets[1].id) in [
        (item.element_id, item.asset_id) for item in project.slide.bindings
    ]
    with pytest.raises(ValueError, match="割付ルールがありません"):
        propose_ordered_assignment(create_report())


def test_saved_rule_expands_across_two_lists_without_a_list_filter(tmp_path: Path):
    """ルール保存のあとに、リストを1つに絞らなくてもスライドへ候補が広がる。"""
    project = create_report(image_count=2)
    _load_named_list(project, tmp_path / "a", "outer", "外観", 3)
    _load_named_list(project, tmp_path / "b", "inner", "処理", 2)
    rule = AssignmentRule(
        mode="pattern",
        step=1,
        pattern=[
            FrameRef("frame-overall", 0, "comment", "外観", 1),
            FrameRef("frame-compare", 1, "comment", "処理", 1),
        ],
    )
    before_bindings = list(project.slide.bindings)
    proposal = expand_assignment(project, rule)
    assert project.slide.bindings == before_bindings
    assert project.report_slides == []
    slide0 = [item for item in proposal.candidates if item.slide_ordinal == 0 and item.status == "ready"]
    assert [item.asset_name for item in slide0] == ["img_1", "img_1"]
    assert {item.reason for item in slide0} == {"外観 の1番", "処理 の1番"}
    slide1 = [item for item in proposal.candidates if item.slide_ordinal == 1 and item.status == "ready"]
    assert [(item.frame_index, item.item_number) for item in slide1] == [(0, 2), (1, 2)]
    missing = [item for item in proposal.candidates if item.slide_ordinal == 2 and item.status == "missing"]
    assert [item.frame_index for item in missing] == [1]
    applied = accept_ordered_assignment(project)
    assert len(applied) == 5
    assert len(project.report_slides) == 3


def test_step_override_and_duplicate_comment(tmp_path: Path):
    project = create_report(image_count=2)
    _load_named_list(project, tmp_path / "a", "outer", "外観", 4)
    _load_named_list(project, tmp_path / "b", "inner", "処理", 4)
    rule = AssignmentRule(
        mode="pattern",
        step=2,
        pattern=[
            FrameRef("frame-overall", 0, "position", "1", 1),
            FrameRef("frame-compare", 1, "position", "2", 1),
        ],
        overrides=[
            SlideOverride(
                slide_ordinal=1,
                frames=[
                    FrameRef("frame-overall", 0, "name", "inner", 4),
                    FrameRef("frame-compare", 1, "name", "outer", 4),
                ],
            )
        ],
    )
    proposal = expand_assignment(project, rule)
    stepped = [(item.frame_index, item.item_number, item.asset_name) for item in proposal.candidates if item.slide_ordinal == 0]
    assert stepped == [(0, 1, "img_1"), (1, 1, "img_1")]
    override = [(item.frame_index, item.item_number, item.reason) for item in proposal.candidates if item.slide_ordinal == 1]
    assert override == [(0, 4, "処理 の4番"), (1, 4, "外観 の4番")]
    copied = _load_named_list
    duplicate = create_report(image_count=2)
    copied(duplicate, tmp_path / "c", "one", "外観", 1)
    copied(duplicate, tmp_path / "d", "two", "外観", 1)
    set_assignment_rule(
        duplicate,
        AssignmentRule(
            pattern=[FrameRef("frame-overall", 0, "comment", "外観", 1)],
            step=1,
        ),
    )
    conflict = propose_ordered_assignment(duplicate)
    assert conflict.candidates[0].status == "conflict"
    assert "複数" in conflict.candidates[0].reason
    saved = project_to_dict(project)
    saved["contentMaster"]["assignmentRule"] = {
        "mode": "sequential",
        "offset": 1,
        "stride": 2,
        "perSlide": 2,
        "mappings": [],
    }
    migrated = project_from_dict(saved)
    assert migrated.content_master.assignment_rule.pattern[0].list_by == "position"
    assert migrated.content_master.assignment_rule.step == 2


def _load_named_list(project, directory: Path, list_name: str, comment: str, count: int) -> None:
    records = [
        _record(
            _png(directory / f"img_{index}.png"),
            index,
            listName=list_name,
            listComment=comment,
        )
        for index in range(1, count + 1)
    ]
    register_ordered_assets(project, records)


def _asset_is_bound(project, asset_id: str) -> bool:
    slides = [item.slide for item in project.report_slides] or [project.slide]
    return any(binding.asset_id == asset_id for slide in slides for binding in slide.bindings)
