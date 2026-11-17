import json
import os
from pathlib import Path

import pytest
from PIL import Image

from smart_report_builder.demo import DEFAULT_CAPTION, build_two_image_project
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import layout_result_from_dict, layout_result_to_dict
from smart_report_builder.project_store import (
    load_layout_result,
    load_project,
    missing_asset_paths,
    save_layout_result,
    save_project,
)


def test_reload_restores_master_bindings_and_layout(tmp_path):
    overall, comparison = _write_pair(tmp_path / "images")
    before = {path: path.read_bytes() for path in (overall, comparison)}
    project = build_two_image_project(overall, comparison, (32, 16), (16, 32))
    original_paths = [asset.path for asset in project.assets]
    destination = tmp_path / "reports" / "sample.project.json"

    save_project(project, destination)
    assert [asset.path for asset in project.assets] == original_paths
    for path, blob in before.items():
        assert path.read_bytes() == blob

    stored = json.loads(destination.read_text(encoding="utf-8"))
    assert stored["schemaVersion"] == 2
    assert stored["assets"][0]["path"] == "../images/overall.png"
    assert stored["assets"][1]["path"] == "../images/comparison.png"
    assert DEFAULT_CAPTION in destination.read_text(encoding="utf-8")
    assert b"PNG" not in destination.read_bytes()

    loaded = load_project(destination)
    assert loaded.content_master.id == project.content_master.id
    assert loaded.content_master.name == "画像2枚と説明"
    assert [binding.element_id for binding in loaded.slide.bindings] == [
        binding.element_id for binding in project.slide.bindings
    ]
    assert [binding.asset_id for binding in loaded.slide.bindings] == [
        binding.asset_id for binding in project.slide.bindings
    ]
    assert loaded.assets[0].width_px == 32
    assert loaded.assets[1].height_px == 32
    assert Path(loaded.assets[0].path) == Path(original_paths[0])
    assert Path(loaded.assets[1].path) == Path(original_paths[1])
    assert missing_asset_paths(loaded) == []

    caption = loaded.content_master.root.children[1]
    assert caption.text == DEFAULT_CAPTION
    assert _signature(layout_slide(loaded)) == _signature(layout_slide(project))


def test_layout_json_round_trip_matches_the_reloaded_project(tmp_path):
    overall, comparison = _write_pair(tmp_path / "images")
    project = build_two_image_project(overall, comparison, (32, 16), (16, 32))
    project_path = tmp_path / "sample.project.json"
    save_project(project, project_path)
    result = layout_slide(load_project(project_path))

    layout_path = tmp_path / "sample.layout.json"
    save_layout_result(result, layout_path)
    restored = load_layout_result(layout_path)
    assert layout_result_to_dict(restored) == json.loads(json.dumps(layout_result_to_dict(result)))
    assert layout_result_from_dict(layout_result_to_dict(result)).elements[2].text == DEFAULT_CAPTION
    assert restored.elements[0].content_rect == result.elements[0].content_rect
    assert not (layout_path.parent / f"{layout_path.name}.tmp").exists()


def test_missing_image_is_reported_without_blocking_load(tmp_path):
    overall = tmp_path / "overall.png"
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (8, 4), (1, 2, 3)).save(overall, format="PNG")
    Image.new("RGB", (4, 8), (3, 2, 1)).save(comparison, format="PNG")
    project = build_two_image_project(overall, comparison, (8, 4), (4, 8))
    destination = tmp_path / "sample.project.json"
    save_project(project, destination)
    comparison.unlink()

    loaded = load_project(destination)
    missing = missing_asset_paths(loaded)
    assert missing == [str(comparison.resolve())]
    result = layout_slide(loaded)
    assert result.elements[2].text == DEFAULT_CAPTION
    assert result.elements[0].content_rect is not None
    assert result.elements[1].content_rect is not None


def test_invalid_json_and_schema_are_rejected(tmp_path):
    destination = tmp_path / "broken.project.json"
    destination.write_text("{", encoding="utf-8")
    with pytest.raises(ValueError, match="JSON"):
        load_project(destination)

    overall, comparison = _write_pair(tmp_path)
    save_project(build_two_image_project(overall, comparison, (8, 4), (4, 8)), destination)
    payload = json.loads(destination.read_text(encoding="utf-8"))
    payload["schemaVersion"] = 999
    destination.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="schemaVersion"):
        load_project(destination)

    payload["schemaVersion"] = 1
    layout_path = tmp_path / "layout.json"
    layout_path.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="missing field"):
        load_layout_result(layout_path)


def test_path_on_another_drive_stays_absolute(tmp_path):
    if os.name != "nt":
        pytest.skip("drive letters are specific to Windows")
    foreign_drive = "D:" if tmp_path.drive.lower() != "d:" else "E:"
    foreign = Path(f"{foreign_drive}/srb_external_asset.png")
    project = build_two_image_project(foreign, foreign, (10, 10), (10, 20))
    destination = tmp_path / "external.project.json"
    save_project(project, destination)
    stored = json.loads(destination.read_text(encoding="utf-8"))["assets"][0]["path"]
    assert Path(stored).is_absolute()
    loaded = load_project(destination)
    assert Path(loaded.assets[0].path) == Path(project.assets[0].path)
    assert missing_asset_paths(loaded)


def _write_pair(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    overall = directory / "overall.png"
    comparison = directory / "comparison.png"
    Image.new("RGB", (32, 16), (47, 111, 176)).save(overall, format="PNG")
    Image.new("RGB", (16, 32), (196, 122, 48)).save(comparison, format="PNG")
    return overall, comparison


def _signature(result):
    return [
        (element.element_id, element.frame, element.content_rect, element.text, element.asset_path)
        for element in result.elements
    ]
