from pathlib import Path

import pytest
from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE

from smart_report_builder.demo import DEFAULT_CAPTION
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import (
    Asset,
    Binding,
    GridNode,
    StackNode,
    TextNode,
    project_from_dict,
    project_to_dict,
)
from smart_report_builder.project_factory import create_report
from smart_report_builder.project_store import load_layout_result, load_project
from smart_report_builder.roi_edit import main


def test_new_horizontal_project_matches_the_two_image_frames_without_assets():
    project = create_report(image_count=2, arrangement="horizontal")
    result = layout_slide(project)
    overall, compare, caption = result.elements
    assert result.preview_mode == "provisional"
    assert project.assets == []
    assert project.slide.bindings == []
    assert overall.display_name == "全体画像"
    assert compare.display_name == "比較画像"
    assert overall.content_rect is None
    assert_rect(overall.frame, 36, 36, 438, 360)
    assert_rect(compare.frame, 486, 36, 438, 360)
    assert_rect(caption.frame, 36, 408, 888, 96)
    assert caption.text == DEFAULT_CAPTION
    assert any(item.code == "unassigned_image" for item in result.violations)


def test_vertical_and_grid_keep_the_caption_and_follow_the_image_count():
    vertical = layout_slide(create_report(image_count=2, arrangement="vertical"))
    assert_rect(vertical.elements[0].frame, 36, 36, 888, 174)
    assert_rect(vertical.elements[1].frame, 36, 222, 888, 174)
    assert_rect(vertical.elements[2].frame, 36, 408, 888, 96)

    grid = layout_slide(create_report(image_count=4, arrangement="grid"))
    assert isinstance(create_report(image_count=4, arrangement="grid").content_master.root.children[0], GridNode)
    assert_rect(grid.elements[0].frame, 36, 36, 438, 174)
    assert_rect(grid.elements[1].frame, 486, 36, 438, 174)
    assert_rect(grid.elements[2].frame, 36, 222, 438, 174)
    assert_rect(grid.elements[3].frame, 486, 222, 438, 174)
    assert_rect(grid.elements[4].frame, 36, 408, 888, 96)

    three = layout_slide(create_report(image_count=3, arrangement="horizontal"))
    assert three.elements[0].frame.width == pytest.approx(288)
    assert three.elements[1].frame.x == pytest.approx(336)
    assert three.elements[2].frame.x == pytest.approx(636)
    assert_rect(three.elements[3].frame, 36, 408, 888, 96)


def test_assigned_image_aspect_moves_the_next_frame_and_keeps_the_caption():
    project = create_report(image_count=2, arrangement="horizontal")
    project.assets = [
        Asset(id="asset-a", path="a.png", width_px=800, height_px=400, display_name="広い"),
        Asset(id="asset-b", path="b.png", width_px=400, height_px=800, display_name="高い"),
    ]
    project.slide.bindings = [
        Binding(element_id="frame-overall", asset_id="asset-a"),
        Binding(element_id="frame-compare", asset_id="asset-b"),
    ]
    result = layout_slide(project)
    overall, compare, caption = result.elements
    assert result.preview_mode == "real"
    assert overall.frame.width == pytest.approx(700.8)
    assert compare.frame.x == pytest.approx(748.8)
    assert compare.frame.width == pytest.approx(175.2)
    assert_rect(caption.frame, 36, 408, 888, 96)
    assert caption.text == DEFAULT_CAPTION

    project.assets[0].width_px = 400
    project.assets[0].height_px = 400
    followed = layout_slide(project)
    assert followed.elements[1].frame.x == pytest.approx(632)
    assert followed.elements[1].frame.x < compare.frame.x
    assert_rect(followed.elements[2].frame, 36, 408, 888, 96)


def test_one_assigned_image_is_a_partial_preview():
    project = create_report(image_count=2, arrangement="horizontal")
    project.assets = [
        Asset(id="asset-a", path="a.png", width_px=800, height_px=400, display_name="広い"),
    ]
    project.slide.bindings = [Binding(element_id="frame-overall", asset_id="asset-a")]
    result = layout_slide(project)
    assert result.preview_mode == "partial"
    assert result.elements[0].content_rect is not None
    assert result.elements[1].content_rect is None


def test_overall_and_zoom_can_be_created_before_any_image_is_registered():
    project = create_report(template="overall-zoom", arrangement="horizontal")
    result = layout_slide(project)
    overall, zoom, caption = result.elements
    assert result.preview_mode == "provisional"
    assert overall.display_name == "全体画像"
    assert zoom.display_name == "拡大画像"
    assert zoom.fit_mode == "roi"
    assert overall.content_rect is None
    assert caption.text == DEFAULT_CAPTION
    restored = project_from_dict(project_to_dict(project))
    assert restored.assets == []
    assert restored.slide.bindings == []
    assert restored.slide.rois == []
    assert restored.content_master.name == "全体画像と拡大"


def test_a_frame_that_becomes_too_small_is_flagged_without_shortening_text():
    project = create_report(image_count=2, arrangement="vertical")
    images = project.content_master.root.children[0]
    assert isinstance(images, StackNode)
    caption = project.content_master.root.children[1]
    assert isinstance(caption, TextNode)
    caption.height_pt = 400
    result = layout_slide(project)
    assert result.elements[2].text == DEFAULT_CAPTION
    assert result.elements[2].frame.height == pytest.approx(400)
    assert result.elements[0].frame.height == pytest.approx(22)
    assert {item.element_id for item in result.violations if item.message == "枠が小さすぎる"} == {
        "frame-overall",
        "frame-compare",
    }


def test_rejected_image_counts_do_not_build_a_project():
    with pytest.raises(ValueError, match="2〜4"):
        create_report(image_count=1)
    with pytest.raises(ValueError, match="2〜4"):
        create_report(image_count=5)


def test_new_project_command_saves_and_refuses_to_overwrite(tmp_path: Path):
    directory = tmp_path / "report"
    assert main(["new-project", str(directory), "--images", "3", "--arrangement", "grid"]) == 0
    project = load_project(directory / "project.json")
    assert project.content_master.name == "画像3枚と説明"
    assert isinstance(project.content_master.root.children[0], GridNode)
    layout = (directory / "layout.json").read_text(encoding="utf-8")
    assert '"previewMode": "provisional"' in layout
    presentation = Presentation(directory / "report.pptx")
    shapes = list(presentation.slides[0].shapes)
    assert sum(shape.shape_type == MSO_SHAPE_TYPE.PICTURE for shape in shapes) == 0
    assert any(shape.has_text_frame and DEFAULT_CAPTION in shape.text_frame.text for shape in shapes)

    before = (directory / "project.json").read_bytes()
    assert main(["new-project", str(directory)]) == 1
    assert (directory / "project.json").read_bytes() == before
    assert main(["new-project", str(directory), "--images", "2", "--replace"]) == 0
    replaced = load_project(directory / "project.json")
    assert replaced.content_master.name == "画像2枚と説明"


def test_added_layouts_stay_in_one_project_and_one_pptx(tmp_path: Path):
    directory = tmp_path / "report"
    assert main(["new-project", str(directory), "--images", "2"]) == 0
    project_path = directory / "project.json"
    layout_path = directory / "layout.json"
    pptx_path = directory / "report.pptx"
    assert "pages" not in project_path.read_text(encoding="utf-8")

    assert (
        main(
            [
                "add-layout",
                str(project_path),
                "--template",
                "overall-zoom",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    documents = sorted(
        path.name for path in directory.glob("*.json") if "history" not in path.name
    )
    assert documents == ["layout.json", "project.json"]
    assert pptx_path.is_file()
    project = load_project(project_path)
    assert [item.name for item in project.layouts] == ["画像2枚と説明", "全体画像と拡大"]
    assert [item.layout_id for item in project.report_slides] == ["layout-1", "layout-2"]
    assert project.active_slide_id == "slide-2"
    assert project.content_master.name == "全体画像と拡大"
    assert project.layouts[0].content_master.name == "画像2枚と説明"
    added = load_layout_result(layout_path)
    assert "frame-zoom" in {element.element_id for element in added.elements}
    assert len(Presentation(pptx_path).slides) == 2

    assert (
        main(
            [
                "resize-frame",
                str(project_path),
                "frame-overall",
                "0.1",
                "0.1",
                "0.4",
                "0.5",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    edited = load_project(project_path)
    assert not _has_free_rect(edited.layouts[0].content_master.root)
    assert _has_free_rect(edited.layouts[1].content_master.root)
    assert len(Presentation(pptx_path).slides) == 2

    assert (
        main(
            [
                "activate-layout",
                str(project_path),
                "slide-1",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    shown = load_layout_result(layout_path)
    assert "frame-compare" in {element.element_id for element in shown.elements}
    restored = load_project(project_path)
    assert restored.active_slide_id == "slide-1"
    assert len(restored.report_slides) == 2
    assert len(Presentation(pptx_path).slides) == 2

    assert (
        main(
            [
                "add-layout",
                str(project_path),
                "--images",
                "3",
                "--arrangement",
                "grid",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    assert (
        main(
            [
                "remove-layout",
                str(project_path),
                "slide-2",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    kept = load_project(project_path)
    assert [item.id for item in kept.report_slides] == ["slide-1", "slide-3"]
    assert kept.active_slide_id == "slide-3"
    assert len(Presentation(pptx_path).slides) == 2

    assert (
        main(
            [
                "remove-layout",
                str(project_path),
                "slide-3",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    last = load_project(project_path)
    assert last.report_slides == []
    assert last.layouts == []
    assert "slides" not in project_path.read_text(encoding="utf-8")
    assert last.content_master.name == "画像2枚と説明"
    shown_last = load_layout_result(layout_path)
    assert "frame-compare" in {element.element_id for element in shown_last.elements}
    assert len(Presentation(pptx_path).slides) == 1
    assert (
        main(
            [
                "remove-layout",
                str(project_path),
                "slide-1",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 1
    )


def test_several_slides_can_use_one_layout(tmp_path: Path):
    directory = tmp_path / "report"
    assert main(["new-project", str(directory), "--images", "2"]) == 0
    project_path = directory / "project.json"
    layout_path = directory / "layout.json"
    pptx_path = directory / "report.pptx"
    assert main(["add-slide", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    shared = load_project(project_path)
    assert [item.layout_id for item in shared.report_slides] == ["layout-1", "layout-1"]
    assert shared.report_slides[0].slide.bindings == []
    assert len(Presentation(pptx_path).slides) == 2

    assert (
        main(
            [
                "add-layout",
                str(project_path),
                "--template",
                "overall-zoom",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    assert (
        main(
            [
                "set-slide-layout",
                str(project_path),
                "slide-2",
                "layout-2",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    project = load_project(project_path)
    assert [item.layout_id for item in project.report_slides] == ["layout-1", "layout-2", "layout-2"]
    assert project.report_slides[1].slide.content_master_id == project.layouts[1].content_master.id
    assert len(Presentation(pptx_path).slides) == 3


def _has_free_rect(node) -> bool:
    if getattr(node, "free_rect", None) is not None:
        return True
    return any(_has_free_rect(child) for child in getattr(node, "children", []))


def assert_rect(rect, x: float, y: float, width: float, height: float) -> None:
    assert rect.x == pytest.approx(x)
    assert rect.y == pytest.approx(y)
    assert rect.width == pytest.approx(width)
    assert rect.height == pytest.approx(height)
