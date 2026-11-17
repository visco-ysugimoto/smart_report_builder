import json

import pytest

from smart_report_builder.demo import DEFAULT_CAPTION, build_two_image_project
from smart_report_builder.models import SCHEMA_VERSION, new_id, project_from_dict, project_to_dict


def test_project_round_trip_keeps_ids_text_and_schema():
    project = build_two_image_project()
    payload = project_to_dict(project)
    assert payload["schemaVersion"] == SCHEMA_VERSION
    restored = project_from_dict(json.loads(json.dumps(payload)))
    assert project_to_dict(restored) == payload
    assert restored.design_master.id == project.design_master.id
    assert restored.content_master.id == project.content_master.id
    assert restored.slide.id == project.slide.id
    assert restored.assets[0].id == "asset-overall"
    assert restored.assets[0].width_px == 800
    text = restored.content_master.root.children[1]
    assert text.text == DEFAULT_CAPTION
    assert text.display_name == "説明"


def test_unknown_schema_fit_and_asset_kind_are_rejected():
    payload = project_to_dict(build_two_image_project())
    future = json.loads(json.dumps(payload))
    future["schemaVersion"] = 999
    with pytest.raises(ValueError, match="schemaVersion"):
        project_from_dict(future)

    bad_fit = json.loads(json.dumps(payload))
    bad_fit["contentMaster"]["root"]["children"][0]["children"][0]["fitMode"] = "stretch"
    with pytest.raises(ValueError):
        project_from_dict(bad_fit)

    bad_asset = json.loads(json.dumps(payload))
    bad_asset["assets"][0]["kind"] = "table"
    with pytest.raises(ValueError, match="asset kind"):
        project_from_dict(bad_asset)

    missing = json.loads(json.dumps(payload))
    del missing["slide"]
    with pytest.raises(ValueError, match="missing field"):
        project_from_dict(missing)


def test_new_id_is_stable_for_the_caller_and_not_reused():
    first = new_id()
    second = new_id()
    assert first != second
    assert first.strip() == first
    assert len(first) >= 16
