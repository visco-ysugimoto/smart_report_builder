from pathlib import Path

import pytest
from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE

from smart_report_builder.demo import DEFAULT_CAPTION
from smart_report_builder.edit_session import EditSession
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import TextNode
from smart_report_builder.practical import set_slide_finding
from smart_report_builder.project_factory import create_report
from smart_report_builder.project_store import load_project, save_project
from smart_report_builder.pptx_writer import write_pptx
from smart_report_builder.roi_edit import activate_page, add_slide, main


def _caption(project) -> TextNode:
    node = project.content_master.root.children[-1]
    assert isinstance(node, TextNode)
    return node


def _placed_text(project) -> str:
    placed = next(item for item in layout_slide(project).elements if item.kind == "text")
    assert placed.text is not None
    return placed.text


def test_finding_is_stored_on_the_slide_and_not_the_master():
    project = create_report()
    master = _caption(project).text
    finding = "  キズが2箇所。\n測定値は短縮しない。  "
    element_id = set_slide_finding(project, finding)
    assert element_id == "text-caption"
    assert _caption(project).text == master
    assert project.slide.bindings[-1].text == finding
    assert _placed_text(project) == finding


def test_each_slide_keeps_its_own_finding_when_the_layout_is_shared():
    project = create_report()
    first_id = project.slide.id
    second_id = add_slide(project)
    set_slide_finding(project, "2枚目だけの見解")
    assert _placed_text(project) == "2枚目だけの見解"
    activate_page(project, first_id)
    assert _placed_text(project) == DEFAULT_CAPTION
    assert all(item.text is None for item in project.slide.bindings)
    activate_page(project, second_id)
    assert _placed_text(project) == "2枚目だけの見解"
    assert _caption(project).text == DEFAULT_CAPTION


def test_empty_finding_is_kept_and_long_text_is_flagged_without_truncation(tmp_path: Path):
    project = create_report()
    set_slide_finding(project, "")
    assert _placed_text(project) == ""
    assert all(item.code != "text_overflow" for item in layout_slide(project).violations)

    long_text = "見解" * 400
    set_slide_finding(project, long_text)
    result = layout_slide(project)
    placed = next(item for item in result.elements if item.element_id == "text-caption")
    assert placed.text == long_text
    assert any(item.code == "text_overflow" and item.element_id == "text-caption" for item in result.violations)
    destination = tmp_path / "finding.pptx"
    write_pptx(result, destination)
    box = next(
        shape
        for shape in Presentation(destination).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.TEXT_BOX
    )
    assert box.text_frame.text == long_text


def test_missing_text_frame_does_not_change_the_slide():
    project = create_report()
    root = project.content_master.root
    root.children = [child for child in root.children if not isinstance(child, TextNode)]
    before = [item.text for item in project.slide.bindings]
    with pytest.raises(ValueError, match="文章枠がありません"):
        set_slide_finding(project, "書けない")
    assert [item.text for item in project.slide.bindings] == before
    with pytest.raises(ValueError, match="見つからない"):
        set_slide_finding(create_report(), "x", "missing-text")


def test_finding_command_stays_in_memory_until_save(tmp_path: Path):
    project_path = tmp_path / "layout.project.json"
    layout_path = tmp_path / "layout.layout.json"
    pptx_path = tmp_path / "layout.pptx"
    save_project(create_report(), project_path)
    before = project_path.read_bytes()
    session = EditSession()
    session.open(str(project_path), str(layout_path), str(pptx_path))
    rejected = session.run(
        ["set-finding", str(project_path), "--element", "missing", "--text", "残す", "--layout", str(layout_path)]
    )
    assert rejected["code"] == 1
    assert rejected["dirty"] is False
    assert project_path.read_bytes() == before

    updated = session.run(
        [
            "set-finding",
            str(project_path),
            "--text",
            "保存前の見解",
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )
    assert updated["code"] == 0
    assert updated["dirty"] is True
    assert updated["layout"]["elements"]
    text = next(item["text"] for item in updated["layout"]["elements"] if item["kind"] == "text")
    assert text == "保存前の見解"
    assert project_path.read_bytes() == before
    assert not pptx_path.exists()

    saved = session.save()
    assert saved["code"] == 0
    assert saved["dirty"] is False
    loaded = load_project(project_path)
    assert loaded.slide.bindings[-1].text == "保存前の見解"
    assert _caption(loaded).text == DEFAULT_CAPTION
    box = next(
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.TEXT_BOX
    )
    assert box.text_frame.text == "保存前の見解"


def test_finding_command_rejects_a_missing_frame_without_writing(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    path = tmp_path / "project.json"
    save_project(create_report(), path)
    before = path.read_bytes()
    assert main(["set-finding", str(path), "--element", "nope", "--text", "残る"]) == 1
    assert "見つからない" in capsys.readouterr().err
    assert path.read_bytes() == before
