import ast
from pathlib import Path

import pytest

from smart_report_builder.demo import (
    ASSET_COMPARE_ID,
    DEFAULT_CAPTION,
    FRAME_COMPARE_ID,
    FRAME_OVERALL_ID,
    ROI_ID,
    TEXT_ID,
    ZOOM_FRAME_ID,
    build_roi_project,
    build_two_image_project,
)
from smart_report_builder.fit import contain_rect
from smart_report_builder.layout import UnsupportedFitModeError, layout_slide
from smart_report_builder.models import (
    Binding,
    CoordSpace,
    FitMode,
    Roi,
    project_from_dict,
    project_to_dict,
)


def test_layout_and_fit_do_not_import_pptx_or_pillow():
    for module_name in ("fit.py", "layout.py", "models.py", "units.py", "project_store.py"):
        source_path = Path(__file__).parents[1] / "src" / "smart_report_builder" / module_name
        tree = ast.parse(source_path.read_text(encoding="utf-8"))
        imported: list[str] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.extend(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.append(node.module)
        assert all("pptx" not in name and "PIL" not in name for name in imported)


def test_two_images_and_caption_use_the_content_box():
    result = layout_slide(build_two_image_project())
    assert result.violations == []
    overall, compare, caption = result.elements

    assert_rect(overall.frame, 36, 36, 438, 360)
    assert_rect(compare.frame, 486, 36, 438, 360)
    assert_rect(caption.frame, 36, 408, 888, 96)
    assert_rect(overall.content_rect, 36, 106.5, 438, 219)
    assert_rect(compare.content_rect, 615, 36, 180, 360)
    assert overall.content_rect == contain_rect(overall.frame, 800, 400)
    assert compare.content_rect == contain_rect(compare.frame, 400, 800)
    assert caption.text == DEFAULT_CAPTION
    assert overall.frame.x + overall.frame.width <= compare.frame.x
    assert overall.frame.y + overall.frame.height <= caption.frame.y


def test_same_input_returns_the_same_layout_without_mutating_the_project():
    project = build_two_image_project()
    before = project_to_dict(project)
    first = layout_slide(project)
    second = layout_slide(project)
    assert project_to_dict(project) == before
    assert _signature(first) == _signature(second)


def test_role_names_do_not_change_placement():
    original = layout_slide(build_two_image_project())
    renamed = build_two_image_project()
    image_row = renamed.content_master.root.children[0]
    image_row.children[0].role_id = "custom-a"
    image_row.children[0].display_name = "別名A"
    image_row.children[1].role_id = "custom-b"
    image_row.children[1].display_name = "別名B"
    moved = layout_slide(renamed)
    assert [element.frame for element in moved.elements] == [
        element.frame for element in original.elements
    ]
    assert [element.content_rect for element in moved.elements] == [
        element.content_rect for element in original.elements
    ]


def test_unassigned_images_keep_frames_and_full_text():
    result = layout_slide(build_two_image_project(assign_images=False))
    images = [element for element in result.elements if element.kind == "image_frame"]
    caption = result.elements[2]
    assert len(images) == 2
    assert all(element.content_rect is None and element.asset_path is None for element in images)
    assert_rect(images[0].frame, 36, 36, 438, 360)
    assert caption.text == DEFAULT_CAPTION
    assert caption.display_name == "説明"
    assert [item.code for item in result.violations] == ["unassigned_image", "unassigned_image"]


def test_binding_text_replaces_the_master_text_without_shortening():
    full_text = DEFAULT_CAPTION + "追加の全文です。末尾マーカーEND"
    project = build_two_image_project(
        bindings=[
            Binding(element_id=FRAME_OVERALL_ID, asset_id="asset-overall"),
            Binding(element_id=FRAME_COMPARE_ID, asset_id="asset-compare"),
            Binding(element_id=TEXT_ID, text=full_text),
        ]
    )
    caption = layout_slide(project).elements[2]
    assert caption.text == full_text
    assert caption.text.endswith("末尾マーカーEND")


def test_conflicting_bindings_are_not_resolved_silently():
    project = build_two_image_project()
    project.slide.bindings.append(Binding(FRAME_OVERALL_ID, asset_id=ASSET_COMPARE_ID))
    project.slide.bindings.append(Binding(TEXT_ID, text="one"))
    project.slide.bindings.append(Binding(TEXT_ID, text="two"))
    result = layout_slide(project)
    codes = [item.code for item in result.violations]
    assert codes.count("binding_conflict") == 2
    assert "unassigned_image" in codes
    assert result.elements[0].asset_path is None
    assert result.elements[0].content_rect is None
    assert result.elements[2].text == DEFAULT_CAPTION


def test_missing_asset_and_invalid_pixel_size_do_not_drop_text():
    missing = layout_slide(
        build_two_image_project(
            bindings=[Binding(element_id=FRAME_OVERALL_ID, asset_id="does-not-exist")]
        )
    )
    assert any(item.code == "missing_asset" for item in missing.violations)
    assert missing.elements[0].content_rect is None
    assert missing.elements[2].text == DEFAULT_CAPTION

    invalid = layout_slide(build_two_image_project(overall_px=(0, 400)))
    assert any(
        item.code == "invalid_image_size" and item.element_id == FRAME_OVERALL_ID
        for item in invalid.violations
    )
    assert invalid.elements[0].content_rect is None
    assert invalid.elements[0].asset_path is not None
    assert invalid.elements[1].content_rect is not None
    assert invalid.elements[2].text == DEFAULT_CAPTION


def test_text_that_does_not_fit_is_flagged_and_not_shortened():
    project = build_two_image_project(text_height_pt=1000)
    before_assets = list(project.assets)
    result = layout_slide(project)
    caption = result.elements[2]
    assert caption.text == DEFAULT_CAPTION
    assert caption.frame.height == pytest.approx(1000)
    assert any(item.code == "overflow" and item.element_id == TEXT_ID for item in result.violations)
    assert project.assets == before_assets


def test_negative_gap_is_reported_and_not_pulled_apart():
    result = layout_slide(build_two_image_project(image_gap_pt=-100))
    overall, compare, _caption = result.elements
    assert overall.frame.x + overall.frame.width > compare.frame.x + 1
    assert any(item.code == "overlap" and item.element_id == FRAME_COMPARE_ID for item in result.violations)


def test_roi_stays_on_the_source_image_and_fills_the_zoom_frame():
    result = layout_slide(build_roi_project("overall.png", (800, 400)))
    assert result.violations == []
    overall = result.elements[0]
    zoom = result.elements[1]
    roi = next(element for element in result.elements if element.kind == "roi")
    assert overall.crop is None
    assert overall.fit_mode == "contain"
    assert_rect(overall.content_rect, 36, 106.5, 438, 219)
    assert_rect(roi.frame, 79.8, 150.3, 87.6, 131.4)
    assert roi.source_element_id == FRAME_OVERALL_ID
    assert_rect(zoom.content_rect, 585, 36, 240, 360)
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.1)
    assert zoom.crop.y == pytest.approx(0.2)
    assert zoom.crop.width == pytest.approx(0.2)
    assert zoom.crop.height == pytest.approx(0.6)
    assert zoom.asset_path == overall.asset_path
    assert result.elements[2].text == DEFAULT_CAPTION


def test_pixel_roi_matches_the_same_normalized_region():
    normalized = layout_slide(build_roi_project("overall.png", (800, 400)))
    pixel = build_roi_project(
        "overall.png",
        (800, 400),
        roi=Roi(
            id=ROI_ID,
            name="ROI",
            source_element_id=FRAME_OVERALL_ID,
            zoom_element_id=ZOOM_FRAME_ID,
            x=80,
            y=80,
            width=160,
            height=240,
            coord_space=CoordSpace.PIXEL,
        ),
    )
    pixel_result = layout_slide(pixel)
    assert _signature(pixel_result) == _signature(normalized)


def test_out_of_bounds_roi_is_not_applied():
    project = build_roi_project(
        "overall.png",
        (800, 400),
        roi=Roi(
            id=ROI_ID,
            name="ROI",
            source_element_id=FRAME_OVERALL_ID,
            zoom_element_id=ZOOM_FRAME_ID,
            x=0.9,
            y=0.1,
            width=0.2,
            height=0.2,
        ),
    )
    result = layout_slide(project)
    assert any(item.code == "roi_out_of_bounds" for item in result.violations)
    assert all(element.kind != "roi" for element in result.elements)
    zoom = next(element for element in result.elements if element.element_id == ZOOM_FRAME_ID)
    assert zoom.content_rect is None
    assert result.elements[2].text == DEFAULT_CAPTION
    restored = project_from_dict(project_to_dict(project))
    assert restored.slide.rois[0].x == pytest.approx(0.9)


def test_project_without_rois_still_loads():
    payload = project_to_dict(build_two_image_project())
    del payload["slide"]["rois"]
    loaded = project_from_dict(payload)
    assert loaded.slide.rois == []


def test_note_is_an_anchored_label_and_does_not_move_the_roi():
    project = build_roi_project("overall.png", (800, 400))
    project.slide.rois[0].note = "  傷の注釈  "
    result = layout_slide(project)
    roi = next(item for item in result.elements if item.element_id == ROI_ID)
    label = next(item for item in result.elements if item.kind == "roi_label")
    connector = next(item for item in result.elements if item.kind == "connector")
    caption = next(item for item in result.elements if item.kind == "text")
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    assert_rect(roi.frame, 79.8, 150.3, 87.6, 131.4)
    assert label.text == "傷の注釈"
    assert label.element_id == f"{ROI_ID}-note"
    assert label.frame.x == pytest.approx(roi.frame.x + roi.frame.width + 12)
    assert label.frame.y == pytest.approx(roi.frame.y + (roi.frame.height - 64) / 2)
    assert label.frame.width == pytest.approx(180)
    assert label.frame.height == pytest.approx(64)
    assert connector.element_id == f"{ROI_ID}-connector"
    assert connector.line_start is not None and connector.line_end is not None
    assert connector.line_start.x == pytest.approx(roi.frame.x + roi.frame.width)
    assert connector.line_end.x == pytest.approx(label.frame.x)
    assert connector.line_start.y == pytest.approx(connector.line_end.y)
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.1)
    assert caption.text == DEFAULT_CAPTION
    assert result.violations == []

    project.slide.rois[0].note = "   "
    cleared = layout_slide(project)
    assert all(item.kind not in {"roi_label", "connector"} for item in cleared.elements)
    payload = project_to_dict(project)
    del payload["slide"]["rois"][0]["note"]
    assert project_from_dict(payload).slide.rois[0].note == ""


def test_manual_note_offset_stays_on_the_slide():
    project = build_roi_project("overall.png", (800, 400))
    roi = project.slide.rois[0]
    roi.note = "傷の注釈"
    roi.note_dx = 40
    roi.note_dy = -10
    label = next(item for item in layout_slide(project).elements if item.kind == "roi_label")
    assert label.frame.x == pytest.approx(79.8 + 87.6 + 12 + 40)
    assert label.frame.y == pytest.approx(150.3 + (131.4 - 64) / 2 - 10)
    assert label.frame.width == pytest.approx(180)
    roi.note_dx = 5000
    roi.note_dy = 5000
    clamped = next(item for item in layout_slide(project).elements if item.kind == "roi_label")
    assert clamped.frame.x == pytest.approx(960 - 180)
    assert clamped.frame.y == pytest.approx(540 - 64)
    assert "noteDx" in project_to_dict(project)["slide"]["rois"][0]
    roi.note_dx = None
    roi.note_dy = None
    assert "noteDx" not in project_to_dict(project)["slide"]["rois"][0]
    partial = project_to_dict(project)
    partial["slide"]["rois"][0]["noteDx"] = 12
    assert project_from_dict(partial).slide.rois[0].note_dx is None


def test_cover_stops_before_cropping():
    project = build_two_image_project(fit_mode=FitMode.COVER)
    with pytest.raises(UnsupportedFitModeError, match="contain"):
        layout_slide(project)


def assert_rect(actual, x: float, y: float, width: float, height: float) -> None:
    assert actual is not None
    assert actual.x == pytest.approx(x)
    assert actual.y == pytest.approx(y)
    assert actual.width == pytest.approx(width)
    assert actual.height == pytest.approx(height)


def _signature(result):
    return [
        (
            element.element_id,
            element.frame,
            element.content_rect,
            element.text,
            element.asset_path,
            [(item.code, item.element_id) for item in result.violations],
        )
        for element in result.elements
    ]
