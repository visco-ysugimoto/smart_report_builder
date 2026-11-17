from pathlib import Path

import pytest
from PIL import Image
from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE

from smart_report_builder.demo import (
    DEFAULT_CAPTION,
    FRAME_COMPARE_ID,
    FRAME_OVERALL_ID,
    ROI_ID,
    ZOOM_FRAME_ID,
    build_roi_project,
    build_two_image_project,
    build_two_zoom_project,
)
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import (
    Binding,
    CoordSpace,
    FitMode,
    GridNode,
    ImageFrameNode,
    Roi,
    StackDirection,
    StackNode,
    TextNode,
)
from smart_report_builder.project_store import load_layout_result, load_project, save_project
from smart_report_builder.roi_edit import (
    add_normalized_roi,
    apply_normalized_roi,
    main,
    redo_snapshot_path,
    undo_snapshot_path,
    zoom_link_label,
)


def test_normalized_edit_rewrites_project_layout_and_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    project = build_roi_project(image, (800, 400))
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(project, project_path)
    before_zoom = _zoom_rect(layout_slide(project))

    code = main(
        [
            str(project_path),
            ROI_ID,
            "0.25",
            "0.10",
            "0.40",
            "0.40",
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )

    assert code == 0
    assert image.read_bytes() == before
    loaded = load_project(project_path)
    roi = loaded.slide.rois[0]
    assert roi.coord_space == CoordSpace.NORMALIZED
    assert roi.x == pytest.approx(0.25)
    assert roi.y == pytest.approx(0.10)
    assert roi.width == pytest.approx(0.40)
    assert roi.height == pytest.approx(0.40)
    result = load_layout_result(layout_path)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.25)
    assert zoom.crop.width == pytest.approx(0.40)
    assert zoom.content_rect != before_zoom
    assert caption.text == DEFAULT_CAPTION
    assert pptx_path.is_file()
    assert result.violations == []


def test_pixel_edit_keeps_pixel_coordinates(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(
        image,
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
    apply_normalized_roi(project, ROI_ID, 0.25, 0.25, 0.5, 0.5)
    roi = project.slide.rois[0]
    assert roi.coord_space == CoordSpace.PIXEL
    assert roi.x == pytest.approx(200)
    assert roi.y == pytest.approx(100)
    assert roi.width == pytest.approx(400)
    assert roi.height == pytest.approx(200)
    zoom = next(item for item in layout_slide(project).elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.25)
    assert zoom.crop.height == pytest.approx(0.5)


def test_out_of_bounds_edit_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(image, (800, 400))
    project_path = tmp_path / "sample_roi.project.json"
    save_project(project, project_path)
    before = project_path.read_bytes()

    code = main([str(project_path), ROI_ID, "0.9", "0.1", "0.2", "0.2"])

    assert code == 1
    assert project_path.read_bytes() == before
    with pytest.raises(ValueError, match="元画像の外"):
        apply_normalized_roi(load_project(project_path), ROI_ID, 0.9, 0.1, 0.2, 0.2)


def test_missing_roi_is_rejected(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main([str(project_path), "missing-roi", "0.1", "0.1", "0.2", "0.2"]) == 1


def test_create_roi_on_a_contain_image_keeps_the_caption_and_source(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = _write_png(tmp_path / "comparison.png")
    before = {path: path.read_bytes() for path in (overall, comparison)}
    project = build_two_image_project(overall, comparison, (800, 400), (400, 800))
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(project, project_path)

    code = main(
        [
            "create",
            str(project_path),
            FRAME_OVERALL_ID,
            "0.25",
            "0.25",
            "0.50",
            "0.50",
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )

    assert code == 0
    for path, blob in before.items():
        assert path.read_bytes() == blob
    loaded = load_project(project_path)
    assert len(loaded.slide.rois) == 1
    roi = loaded.slide.rois[0]
    assert roi.id == "roi-1"
    assert roi.name == "ROI 1"
    assert roi.source_element_id == FRAME_OVERALL_ID
    assert roi.zoom_element_id is None
    assert roi.coord_space == CoordSpace.NORMALIZED
    assert roi.x == pytest.approx(0.25)
    result = load_layout_result(layout_path)
    placed = next(item for item in result.elements if item.element_id == "roi-1")
    assert placed.frame.x == pytest.approx(145.5)
    assert placed.frame.y == pytest.approx(161.25)
    assert placed.frame.width == pytest.approx(219)
    assert placed.frame.height == pytest.approx(109.5)
    caption = next(item for item in result.elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    assert pptx_path.is_file()
    assert result.violations == []


def test_second_roi_does_not_take_an_occupied_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(image, (800, 400))
    project_path = tmp_path / "sample_roi.project.json"
    save_project(project, project_path)

    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.4", "0.1", "0.2", "0.2"]) == 0

    loaded = load_project(project_path)
    original, added = loaded.slide.rois
    assert original.id == ROI_ID
    assert original.x == pytest.approx(0.1)
    assert original.zoom_element_id == ZOOM_FRAME_ID
    assert added.id == "roi-2"
    assert added.zoom_element_id is None
    zoom = next(item for item in layout_slide(loaded).elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.1)
    assert zoom.crop.width == pytest.approx(0.2)


def test_new_roi_links_the_only_free_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(image, (800, 400))
    project.slide.rois.clear()
    project_path = tmp_path / "sample_roi.project.json"
    save_project(project, project_path)

    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.1", "0.2", "0.2", "0.6"]) == 0

    loaded = load_project(project_path)
    roi = loaded.slide.rois[0]
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    zoom = next(item for item in layout_slide(loaded).elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.crop is not None
    assert zoom.crop.height == pytest.approx(0.6)


def test_create_rejects_a_zoom_frame_and_an_out_of_bounds_rect(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(image, (800, 400))
    project_path = tmp_path / "sample_roi.project.json"
    save_project(project, project_path)
    before = project_path.read_bytes()

    assert main(["create", str(project_path), ZOOM_FRAME_ID, "0.1", "0.1", "0.2", "0.2"]) == 1
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.9", "0.1", "0.2", "0.2"]) == 1
    assert project_path.read_bytes() == before
    with pytest.raises(ValueError, match="通常表示"):
        add_normalized_roi(load_project(project_path), FRAME_COMPARE_ID, 0.1, 0.1, 0.2, 0.2)


def test_delete_linked_roi_clears_the_zoom_and_keeps_the_source(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)

    code = main(
        [
            "delete",
            str(project_path),
            ROI_ID,
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )

    assert code == 0
    assert image.read_bytes() == before
    loaded = load_project(project_path)
    assert loaded.slide.rois == []
    result = load_layout_result(layout_path)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert all(item.kind != "roi" for item in result.elements)
    assert zoom.content_rect is None
    assert zoom.crop is None
    assert caption.text == DEFAULT_CAPTION
    slide = Presentation(pptx_path).slides[0]
    pictures = [shape for shape in slide.shapes if shape.shape_type == MSO_SHAPE_TYPE.PICTURE]
    assert len(pictures) == 1
    assert all(shape.name != "ROI" for shape in slide.shapes)


def test_deleting_the_linked_roi_does_not_relink_another(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.4", "0.1", "0.2", "0.2"]) == 0

    assert main(["delete", str(project_path), ROI_ID]) == 0

    loaded = load_project(project_path)
    assert [item.id for item in loaded.slide.rois] == ["roi-2"]
    assert loaded.slide.rois[0].zoom_element_id is None
    assert loaded.slide.rois[0].x == pytest.approx(0.4)
    zoom = next(item for item in layout_slide(loaded).elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.content_rect is None


def test_deleting_an_extra_roi_keeps_the_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.4", "0.1", "0.2", "0.2"]) == 0

    assert main(["delete", str(project_path), "roi-2"]) == 0

    loaded = load_project(project_path)
    assert [item.id for item in loaded.slide.rois] == [ROI_ID]
    assert loaded.slide.rois[0].x == pytest.approx(0.1)
    assert loaded.slide.rois[0].zoom_element_id == ZOOM_FRAME_ID
    zoom = next(item for item in layout_slide(loaded).elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.1)


def test_missing_roi_delete_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()

    assert main(["delete", str(project_path), "missing-roi"]) == 1
    assert project_path.read_bytes() == before


def test_link_moves_the_zoom_without_changing_either_rectangle(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.4", "0.1", "0.2", "0.2"]) == 0

    assert (
        main(
            [
                "link",
                str(project_path),
                "roi-2",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before
    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    added = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert original.zoom_element_id is None
    assert original.x == pytest.approx(0.1)
    assert original.width == pytest.approx(0.2)
    assert added.zoom_element_id == ZOOM_FRAME_ID
    assert added.x == pytest.approx(0.4)
    assert added.y == pytest.approx(0.1)
    assert added.coord_space == CoordSpace.NORMALIZED
    result = load_layout_result(layout_path)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert zoom.crop is not None
    assert zoom.crop.x == pytest.approx(0.4)
    assert zoom.crop.y == pytest.approx(0.1)
    assert caption.text == DEFAULT_CAPTION
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    assert len(pictures) == 2


def test_unlink_keeps_the_roi_and_clears_the_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)

    assert (
        main(["unlink", str(project_path), ROI_ID, "--layout", str(layout_path), "--pptx", str(pptx_path)])
        == 0
    )

    assert image.read_bytes() == before
    loaded = load_project(project_path)
    roi = loaded.slide.rois[0]
    assert roi.id == ROI_ID
    assert roi.zoom_element_id is None
    assert roi.x == pytest.approx(0.1)
    assert roi.height == pytest.approx(0.6)
    result = load_layout_result(layout_path)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.content_rect is None
    assert zoom.crop is None
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    assert len(pictures) == 1


def test_link_without_one_zoom_frame_does_not_change_the_project(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = _write_png(tmp_path / "comparison.png")
    project_path = tmp_path / "sample_a.project.json"
    save_project(build_two_image_project(overall, comparison, (800, 400), (400, 800)), project_path)
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.2", "0.2", "0.2", "0.2"]) == 0
    before = project_path.read_bytes()

    assert main(["link", str(project_path), "roi-1"]) == 1
    assert project_path.read_bytes() == before

    several = build_roi_project(overall, (800, 400))
    images = several.content_master.root.children[0]
    assert isinstance(images, StackNode)
    images.children.append(
        ImageFrameNode(
            id="frame-zoom-b",
            role_id="zoom-b",
            display_name="拡大2",
            fit_mode=FitMode.ROI,
        )
    )
    several_path = tmp_path / "several.project.json"
    save_project(several, several_path)
    saved = several_path.read_bytes()
    assert main(["link", str(several_path), ROI_ID]) == 1
    assert several_path.read_bytes() == saved
    assert load_project(several_path).slide.rois[0].zoom_element_id == ZOOM_FRAME_ID


def test_chosen_zoom_frame_keeps_the_other_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    project = build_roi_project(image, (800, 400))
    images = project.content_master.root.children[0]
    assert isinstance(images, StackNode)
    images.children.append(
        ImageFrameNode(
            id="frame-zoom-b",
            role_id="zoom-b",
            display_name="拡大2",
            fit_mode=FitMode.ROI,
        )
    )
    project.slide.rois.append(
        Roi(
            id="roi-2",
            name="ROI 2",
            source_element_id=FRAME_OVERALL_ID,
            x=0.4,
            y=0.1,
            width=0.2,
            height=0.2,
        )
    )
    project_path = tmp_path / "several.project.json"
    layout_path = tmp_path / "several.layout.json"
    pptx_path = tmp_path / "several.pptx"
    save_project(project, project_path)

    assert (
        main(
            [
                "link",
                str(project_path),
                "roi-2",
                "--zoom",
                "frame-zoom-b",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before
    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    added = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert original.zoom_element_id == ZOOM_FRAME_ID
    assert original.x == pytest.approx(0.1)
    assert added.zoom_element_id == "frame-zoom-b"
    assert added.x == pytest.approx(0.4)
    result = load_layout_result(layout_path)
    zoom_a = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    zoom_b = next(item for item in result.elements if item.element_id == "frame-zoom-b")
    assert zoom_a.crop is not None and zoom_a.crop.x == pytest.approx(0.1)
    assert zoom_b.crop is not None and zoom_b.crop.x == pytest.approx(0.4)

    assert main(["link", str(project_path), "roi-2", "--zoom", ZOOM_FRAME_ID]) == 0
    moved = load_project(project_path)
    original = next(item for item in moved.slide.rois if item.id == ROI_ID)
    added = next(item for item in moved.slide.rois if item.id == "roi-2")
    assert original.zoom_element_id is None
    assert original.x == pytest.approx(0.1)
    assert added.zoom_element_id == ZOOM_FRAME_ID
    assert added.x == pytest.approx(0.4)
    occupied = project_path.read_bytes()
    assert main(["link", str(project_path), "roi-2", "--zoom", FRAME_OVERALL_ID]) == 1
    assert project_path.read_bytes() == occupied


def test_rename_changes_the_label_and_keeps_the_rectangle(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before_bytes = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = layout_slide(load_project(project_path))
    roi_before = next(item for item in before.elements if item.element_id == ROI_ID)
    zoom_before = next(item for item in before.elements if item.element_id == ZOOM_FRAME_ID)

    assert (
        main(
            [
                "rename",
                str(project_path),
                ROI_ID,
                "--name",
                "  傷A  ",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before_bytes
    loaded = load_project(project_path)
    roi = loaded.slide.rois[0]
    assert roi.id == ROI_ID
    assert roi.name == "傷A"
    assert roi.x == pytest.approx(0.1)
    assert roi.width == pytest.approx(0.2)
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    result = load_layout_result(layout_path)
    placed = next(item for item in result.elements if item.element_id == ROI_ID)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert placed.display_name == "傷A"
    assert placed.frame == roi_before.frame
    assert zoom.crop == zoom_before.crop
    assert caption.text == DEFAULT_CAPTION
    names = [shape.name for shape in Presentation(pptx_path).slides[0].shapes]
    assert "傷A" in names
    assert "ROI" not in names


def test_blank_rename_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()

    assert main(["rename", str(project_path), ROI_ID, "--name", "   "]) == 1
    assert main(["rename", str(project_path), "missing-roi", "--name", "傷A"]) == 1
    assert main(["rename", str(project_path), ROI_ID, "--name", "傷\nA"]) == 1
    assert main(["rename", str(project_path), ROI_ID, "--name", "傷\tA"]) == 1
    assert project_path.read_bytes() == before


def test_duplicate_offsets_the_copy_and_keeps_the_original_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before_bytes = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = layout_slide(load_project(project_path))
    original_frame = next(item for item in before.elements if item.element_id == ROI_ID).frame
    zoom_before = next(item for item in before.elements if item.element_id == ZOOM_FRAME_ID)

    assert (
        main(
            [
                "duplicate",
                str(project_path),
                ROI_ID,
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before_bytes
    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    copied = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert original.name == "ROI"
    assert original.x == pytest.approx(0.1)
    assert original.y == pytest.approx(0.2)
    assert original.width == pytest.approx(0.2)
    assert original.height == pytest.approx(0.6)
    assert original.zoom_element_id == ZOOM_FRAME_ID
    assert copied.name == "ROI のコピー"
    assert copied.source_element_id == FRAME_OVERALL_ID
    assert copied.zoom_element_id is None
    assert copied.coord_space == CoordSpace.NORMALIZED
    assert copied.x == pytest.approx(0.14)
    assert copied.y == pytest.approx(0.24)
    assert copied.width == pytest.approx(0.2)
    assert copied.height == pytest.approx(0.6)
    result = load_layout_result(layout_path)
    placed = next(item for item in result.elements if item.element_id == ROI_ID)
    copy_placed = next(item for item in result.elements if item.element_id == "roi-2")
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert placed.frame == original_frame
    assert placed.display_name == "ROI"
    assert copy_placed.display_name == "ROI のコピー"
    assert copy_placed.frame != original_frame
    assert zoom.crop == zoom_before.crop
    assert caption.text == DEFAULT_CAPTION
    assert result.violations == []
    names = [shape.name for shape in Presentation(pptx_path).slides[0].shapes]
    assert "ROI" in names
    assert "ROI のコピー" in names
    pictures = [
        shape for shape in Presentation(pptx_path).slides[0].shapes if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    assert len(pictures) == 2


def test_duplicate_does_not_take_another_rois_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_zooms.project.json"
    save_project(build_two_zoom_project(image, (800, 400)), project_path)

    assert main(["duplicate", str(project_path), ROI_ID]) == 0

    loaded = load_project(project_path)
    by_id = {item.id: item for item in loaded.slide.rois}
    assert set(by_id) == {ROI_ID, "roi-2", "roi-3"}
    assert by_id[ROI_ID].zoom_element_id == ZOOM_FRAME_ID
    assert by_id[ROI_ID].x == pytest.approx(0.1)
    assert by_id["roi-2"].name == "ROI 2"
    assert by_id["roi-2"].zoom_element_id == "frame-zoom-b"
    assert by_id["roi-2"].x == pytest.approx(0.5)
    assert by_id["roi-3"].name == "ROI のコピー"
    assert by_id["roi-3"].zoom_element_id is None
    assert "roi_conflict" not in {item.code for item in layout_slide(loaded).violations}


def test_duplicate_keeps_pixel_coordinates_and_reuses_a_free_id(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(
        image,
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
    project.slide.rois.append(
        Roi(
            id="roi-3",
            name="端",
            source_element_id=FRAME_OVERALL_ID,
            x=0.9,
            y=0.9,
            width=0.1,
            height=0.1,
        )
    )
    project_path = tmp_path / "pixel.project.json"
    save_project(project, project_path)

    assert main(["duplicate", str(project_path), ROI_ID]) == 0

    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    copied = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert [item.id for item in loaded.slide.rois] == [ROI_ID, "roi-3", "roi-2"]
    assert original.coord_space == CoordSpace.PIXEL
    assert original.x == pytest.approx(80)
    assert original.zoom_element_id == ZOOM_FRAME_ID
    assert copied.coord_space == CoordSpace.PIXEL
    assert copied.x == pytest.approx(96)
    assert copied.y == pytest.approx(96)
    assert copied.width == pytest.approx(160)
    assert copied.height == pytest.approx(240)
    assert copied.zoom_element_id is None
    assert copied.name == "ROI のコピー"


def test_duplicate_stays_put_when_there_is_no_room(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "edge.project.json"
    save_project(
        build_roi_project(
            image,
            (800, 400),
            roi=Roi(
                id=ROI_ID,
                name="ROI",
                source_element_id=FRAME_OVERALL_ID,
                zoom_element_id=ZOOM_FRAME_ID,
                x=0.9,
                y=0.9,
                width=0.1,
                height=0.1,
            ),
        ),
        project_path,
    )

    assert main(["duplicate", str(project_path), ROI_ID]) == 0

    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    copied = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert original.x == pytest.approx(0.9)
    assert original.zoom_element_id == ZOOM_FRAME_ID
    assert copied.x == pytest.approx(0.9)
    assert copied.y == pytest.approx(0.9)
    assert copied.width == pytest.approx(0.1)
    assert copied.zoom_element_id is None


def test_missing_duplicate_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()

    assert main(["duplicate", str(project_path), "missing-roi"]) == 1
    assert project_path.read_bytes() == before


def test_undo_restores_the_last_roi_edit_once(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before_bytes = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    original = project_path.read_bytes()
    before = layout_slide(load_project(project_path))
    roi_before = next(item for item in before.elements if item.element_id == ROI_ID)
    zoom_before = next(item for item in before.elements if item.element_id == ZOOM_FRAME_ID)
    snapshot = undo_snapshot_path(project_path)

    assert (
        main(
            [
                str(project_path),
                ROI_ID,
                "0.25",
                "0.10",
                "0.40",
                "0.40",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )
    moved = project_path.read_bytes()
    assert moved != original
    assert snapshot.read_bytes() == original

    assert main([str(project_path), ROI_ID, "0.9", "0.1", "0.2", "0.2"]) == 1
    assert project_path.read_bytes() == moved
    assert snapshot.read_bytes() == original

    assert (
        main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)])
        == 0
    )
    assert project_path.read_bytes() == original
    assert image.read_bytes() == before_bytes
    assert not snapshot.exists()
    result = load_layout_result(layout_path)
    placed = next(item for item in result.elements if item.element_id == ROI_ID)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert placed.frame == roi_before.frame
    assert zoom.crop == zoom_before.crop
    assert caption.text == DEFAULT_CAPTION
    assert result.violations == []

    assert main(["undo", str(project_path)]) == 1
    assert project_path.read_bytes() == original
    redo = redo_snapshot_path(project_path)
    assert redo.read_bytes() == moved

    assert (
        main(["redo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)])
        == 0
    )
    assert project_path.read_bytes() == moved
    assert image.read_bytes() == before_bytes
    assert snapshot.read_bytes() == original
    assert not redo.exists()
    redone = load_layout_result(layout_path)
    redone_zoom = next(item for item in redone.elements if item.element_id == ZOOM_FRAME_ID)
    assert redone_zoom.crop is not None
    assert redone_zoom.crop.x == pytest.approx(0.25)
    assert redone_zoom.crop.width == pytest.approx(0.40)
    assert main(["redo", str(project_path)]) == 1
    assert project_path.read_bytes() == moved


def test_undo_restores_a_deleted_roi_and_a_transferred_zoom(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)

    assert (
        main(["delete", str(project_path), ROI_ID, "--layout", str(layout_path), "--pptx", str(pptx_path)])
        == 0
    )
    assert load_project(project_path).slide.rois == []
    assert main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    restored = load_project(project_path).slide.rois[0]
    assert restored.id == ROI_ID
    assert restored.name == "ROI"
    assert restored.x == pytest.approx(0.1)
    assert restored.zoom_element_id == ZOOM_FRAME_ID
    result = load_layout_result(layout_path)
    assert any(item.element_id == ROI_ID and item.kind == "roi" for item in result.elements)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.crop is not None
    pictures = [
        shape for shape in Presentation(pptx_path).slides[0].shapes if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    assert len(pictures) == 2

    several_path = tmp_path / "sample_zooms.project.json"
    save_project(build_two_zoom_project(image, (800, 400)), several_path)
    assert main(["link", str(several_path), "roi-2", "--zoom", ZOOM_FRAME_ID]) == 0
    moved = {item.id: item for item in load_project(several_path).slide.rois}
    assert moved[ROI_ID].zoom_element_id is None
    assert moved["roi-2"].zoom_element_id == ZOOM_FRAME_ID
    assert main(["undo", str(several_path)]) == 0
    returned = {item.id: item for item in load_project(several_path).slide.rois}
    assert returned[ROI_ID].zoom_element_id == ZOOM_FRAME_ID
    assert returned[ROI_ID].x == pytest.approx(0.1)
    assert returned["roi-2"].zoom_element_id == "frame-zoom-b"
    assert returned["roi-2"].x == pytest.approx(0.5)
    assert returned["roi-2"].name == "ROI 2"


def test_a_new_edit_drops_redo_and_a_rejected_edit_keeps_it(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main([str(project_path), ROI_ID, "0.25", "0.10", "0.40", "0.40"]) == 0
    moved = project_path.read_bytes()
    assert main(["undo", str(project_path)]) == 0
    redo = redo_snapshot_path(project_path)
    assert redo.read_bytes() == moved

    assert main([str(project_path), ROI_ID, "0.9", "0.1", "0.2", "0.2"]) == 1
    assert redo.read_bytes() == moved
    assert main(["redo", str(project_path)]) == 0
    assert project_path.read_bytes() == moved

    assert main(["undo", str(project_path)]) == 0
    assert main([str(project_path), ROI_ID, "0.30", "0.10", "0.20", "0.20"]) == 0
    assert not redo.exists()
    assert main(["redo", str(project_path)]) == 1
    assert load_project(project_path).slide.rois[0].x == pytest.approx(0.30)


def test_rejected_edit_does_not_create_an_undo_snapshot(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()

    assert main([str(project_path), ROI_ID, "0.9", "0.1", "0.2", "0.2"]) == 1
    assert project_path.read_bytes() == before
    assert not undo_snapshot_path(project_path).exists()
    assert main(["undo", str(project_path)]) == 1
    assert project_path.read_bytes() == before


def test_annotate_keeps_the_full_text_and_the_rectangle(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before_bytes = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    note = "これは短縮してはいけない注釈です。"

    assert (
        main(
            [
                "annotate",
                str(project_path),
                ROI_ID,
                "--text",
                f"  {note}  ",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before_bytes
    roi = load_project(project_path).slide.rois[0]
    assert roi.note == note
    assert roi.x == pytest.approx(0.1)
    assert roi.width == pytest.approx(0.2)
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    result = load_layout_result(layout_path)
    label = next(item for item in result.elements if item.kind == "roi_label")
    caption = next(item for item in result.elements if item.kind == "text")
    assert label.text == note
    assert caption.text == DEFAULT_CAPTION
    shapes = list(Presentation(pptx_path).slides[0].shapes)
    label_shape = next(shape for shape in shapes if shape.name == "ROI の注釈")
    assert label_shape.text_frame.text == note
    connector = next(shape for shape in shapes if shape.name == "ROI の接続線")
    connector_xml = connector._element.xml
    assert connector._element.tag.endswith("cxnSp")
    assert "headEnd" in connector_xml
    assert 'type="triangle"' in connector_xml
    assert "tailEnd" not in connector_xml
    assert any(shape.name == "ROI" for shape in shapes)
    pictures = [shape for shape in shapes if shape.shape_type == MSO_SHAPE_TYPE.PICTURE]
    assert len(pictures) == 2

    assert main(["annotate", str(project_path), ROI_ID, "--text", "   "]) == 0
    cleared = load_project(project_path)
    assert cleared.slide.rois[0].note == ""
    assert cleared.slide.rois[0].x == pytest.approx(0.1)
    assert cleared.slide.rois[0].zoom_element_id == ZOOM_FRAME_ID


def test_rejected_note_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()

    assert main(["annotate", str(project_path), ROI_ID, "--text", "傷\nA"]) == 1
    assert main(["annotate", str(project_path), "missing-roi", "--text", "傷"]) == 1
    assert project_path.read_bytes() == before


def test_duplicate_copies_the_note(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["annotate", str(project_path), ROI_ID, "--text", "傷A"]) == 0

    assert main(["duplicate", str(project_path), ROI_ID]) == 0

    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    copied = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert original.note == "傷A"
    assert original.zoom_element_id == ZOOM_FRAME_ID
    assert copied.note == "傷A"
    assert copied.zoom_element_id is None
    assert copied.name == "ROI のコピー"


def test_place_note_remembers_the_offset_and_follows_the_roi(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before_bytes = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    note = "傷の注釈"
    assert (
        main(
            [
                "annotate",
                str(project_path),
                ROI_ID,
                "--text",
                note,
                "--layout",
                str(layout_path),
            ]
        )
        == 0
    )
    placed = load_layout_result(layout_path)
    label = next(item for item in placed.elements if item.kind == "roi_label")
    target_x = label.frame.x + 40
    target_y = label.frame.y - 10

    assert (
        main(
            [
                "place-note",
                str(project_path),
                ROI_ID,
                str(target_x),
                str(target_y),
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before_bytes
    roi = load_project(project_path).slide.rois[0]
    assert roi.note == note
    assert roi.note_dx == pytest.approx(40)
    assert roi.note_dy == pytest.approx(-10)
    assert roi.x == pytest.approx(0.1)
    assert roi.width == pytest.approx(0.2)
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    moved = load_layout_result(layout_path)
    label = next(item for item in moved.elements if item.kind == "roi_label")
    caption = next(item for item in moved.elements if item.kind == "text")
    assert label.frame.x == pytest.approx(target_x)
    assert label.frame.y == pytest.approx(target_y)
    assert label.text == note
    assert caption.text == DEFAULT_CAPTION
    shapes = list(Presentation(pptx_path).slides[0].shapes)
    label_shape = next(shape for shape in shapes if shape.name == "ROI の注釈")
    assert label_shape.text_frame.text == note

    assert main([str(project_path), ROI_ID, "0.20", "0.20", "0.20", "0.60", "--layout", str(layout_path)]) == 0
    followed = load_project(project_path).slide.rois[0]
    assert followed.note_dx == pytest.approx(40)
    assert followed.note == note
    assert followed.x == pytest.approx(0.20)
    followed.note_dx = None
    followed.note_dy = None
    automatic = next(item for item in layout_slide(followed_project(followed, project_path)).elements if item.kind == "roi_label")
    shown = next(item for item in load_layout_result(layout_path).elements if item.kind == "roi_label")
    assert shown.frame.x == pytest.approx(automatic.frame.x + 40)
    assert shown.frame.y == pytest.approx(automatic.frame.y - 10)


def followed_project(roi, project_path: Path):
    project = load_project(project_path)
    project.slide.rois[0].note_dx = None
    project.slide.rois[0].note_dy = None
    assert project.slide.rois[0].id == roi.id
    return project


def test_rejected_note_position_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()
    assert main(["place-note", str(project_path), ROI_ID, "40", "40"]) == 1
    assert project_path.read_bytes() == before

    assert main(["annotate", str(project_path), ROI_ID, "--text", "傷A"]) == 0
    noted = project_path.read_bytes()
    assert main(["place-note", str(project_path), ROI_ID, "-10", "40"]) == 1
    assert project_path.read_bytes() == noted
    roi = load_project(project_path).slide.rois[0]
    assert roi.note == "傷A"
    assert roi.note_dx is None
    assert roi.x == pytest.approx(0.1)


def test_duplicate_copies_the_note_offset(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["annotate", str(project_path), ROI_ID, "--text", "傷A", "--layout", str(layout_path)]) == 0
    label = next(item for item in load_layout_result(layout_path).elements if item.kind == "roi_label")
    assert main(["place-note", str(project_path), ROI_ID, str(label.frame.x + 20), str(label.frame.y)]) == 0

    assert main(["duplicate", str(project_path), ROI_ID]) == 0

    loaded = load_project(project_path)
    original = next(item for item in loaded.slide.rois if item.id == ROI_ID)
    copied = next(item for item in loaded.slide.rois if item.id == "roi-2")
    assert copied.note == "傷A"
    assert copied.note_dx == pytest.approx(original.note_dx)
    assert copied.note_dy == pytest.approx(original.note_dy)
    assert copied.zoom_element_id is None
    assert original.zoom_element_id == ZOOM_FRAME_ID


def test_reset_note_returns_the_label_to_the_automatic_position(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before_bytes = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)
    note = "傷の注釈"
    assert main(["annotate", str(project_path), ROI_ID, "--text", note, "--layout", str(layout_path)]) == 0
    automatic = next(item for item in load_layout_result(layout_path).elements if item.kind == "roi_label")
    assert (
        main(
            [
                "place-note",
                str(project_path),
                ROI_ID,
                str(automatic.frame.x + 40),
                str(automatic.frame.y - 10),
                "--layout",
                str(layout_path),
            ]
        )
        == 0
    )

    assert (
        main(
            [
                "reset-note",
                str(project_path),
                ROI_ID,
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert image.read_bytes() == before_bytes
    roi = load_project(project_path).slide.rois[0]
    assert roi.note == note
    assert roi.note_dx is None
    assert roi.note_dy is None
    assert '"noteDx"' not in project_path.read_text(encoding="utf-8")
    assert roi.x == pytest.approx(0.1)
    assert roi.width == pytest.approx(0.2)
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    label = next(item for item in load_layout_result(layout_path).elements if item.kind == "roi_label")
    caption = next(item for item in load_layout_result(layout_path).elements if item.kind == "text")
    assert label.frame.x == pytest.approx(automatic.frame.x)
    assert label.frame.y == pytest.approx(automatic.frame.y)
    assert label.text == note
    assert caption.text == DEFAULT_CAPTION
    shapes = list(Presentation(pptx_path).slides[0].shapes)
    label_shape = next(shape for shape in shapes if shape.name == "ROI の注釈")
    assert label_shape.text_frame.text == note


def test_rejected_note_reset_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    before = project_path.read_bytes()
    assert main(["reset-note", str(project_path), ROI_ID]) == 1
    assert main(["reset-note", str(project_path), "missing-roi"]) == 1
    assert project_path.read_bytes() == before

    assert main(["annotate", str(project_path), ROI_ID, "--text", "傷A"]) == 0
    noted = project_path.read_bytes()
    assert main(["reset-note", str(project_path), ROI_ID]) == 1
    assert project_path.read_bytes() == noted
    roi = load_project(project_path).slide.rois[0]
    assert roi.note == "傷A"
    assert roi.note_dx is None
    assert roi.x == pytest.approx(0.1)


def test_assign_replaces_one_frame_and_keeps_the_source_file(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    replacement = tmp_path / "square.png"
    Image.new("RGB", (200, 200), (20, 140, 80)).save(replacement, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    replacement_bytes = replacement.read_bytes()
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(build_two_image_project(overall, comparison), project_path)

    assert (
        main(
            [
                "assign",
                str(project_path),
                FRAME_COMPARE_ID,
                str(replacement),
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    assert replacement.read_bytes() == replacement_bytes
    stored = project_path.read_text(encoding="utf-8")
    assert "square.png" in stored
    assert str(replacement.resolve()) not in stored
    loaded = load_project(project_path)
    compare_binding = next(item for item in loaded.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    overall_binding = next(item for item in loaded.slide.bindings if item.element_id == FRAME_OVERALL_ID)
    compare_asset = next(item for item in loaded.assets if item.id == compare_binding.asset_id)
    overall_asset = next(item for item in loaded.assets if item.id == overall_binding.asset_id)
    assert compare_asset.width_px == 200
    assert compare_asset.height_px == 200
    assert compare_asset.display_name == "square"
    assert Path(compare_asset.path) == replacement.resolve()
    assert overall_asset.width_px == 800
    assert Path(overall_asset.path) == overall.resolve()
    result = load_layout_result(layout_path)
    overall_image = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    compare_image = next(item for item in result.elements if item.element_id == FRAME_COMPARE_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert_assigned_rect(overall_image.content_rect, 36, 106.5, 438, 219)
    assert_assigned_rect(compare_image.content_rect, 525, 36, 360, 360)
    assert caption.text == DEFAULT_CAPTION
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    blobs = [picture.image.blob for picture in pictures]
    assert replacement_bytes in blobs
    assert overall_bytes in blobs
    assert comparison_bytes not in blobs

    assert main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    restored = load_project(project_path)
    restored_binding = next(item for item in restored.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    restored_asset = next(item for item in restored.assets if item.id == restored_binding.asset_id)
    assert Path(restored_asset.path) == comparison.resolve()
    assert restored_asset.width_px == 400
    assert restored_asset.height_px == 800


def test_assign_keeps_roi_coordinates(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    replacement = tmp_path / "wide.png"
    Image.new("RGB", (100, 50), (10, 20, 30)).save(replacement, format="PNG")
    replacement_bytes = replacement.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)

    assert main(["assign", str(project_path), FRAME_OVERALL_ID, str(replacement)]) == 0

    assert image.read_bytes() == before
    assert replacement.read_bytes() == replacement_bytes
    roi = load_project(project_path).slide.rois[0]
    assert roi.x == pytest.approx(0.1)
    assert roi.y == pytest.approx(0.2)
    assert roi.width == pytest.approx(0.2)
    assert roi.height == pytest.approx(0.6)
    assert roi.coord_space == CoordSpace.NORMALIZED
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    assert roi.note == ""


def test_rejected_assignment_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    project = build_two_image_project(image, comparison)
    project.slide.bindings.append(Binding(element_id=FRAME_COMPARE_ID, asset_id="asset-compare"))
    project_path = tmp_path / "sample_a.project.json"
    save_project(project, project_path)
    before = project_path.read_bytes()
    notes = tmp_path / "notes.txt"
    notes.write_text("not an image", encoding="utf-8")

    assert main(["assign", str(project_path), FRAME_COMPARE_ID, str(comparison)]) == 1
    assert main(["assign", str(project_path), "missing-frame", str(comparison)]) == 1
    assert main(["assign", str(project_path), FRAME_COMPARE_ID, str(tmp_path / "missing.png")]) == 1
    assert main(["assign", str(project_path), FRAME_COMPARE_ID, str(notes)]) == 1
    assert project_path.read_bytes() == before

    roi_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), roi_path)
    roi_before = roi_path.read_bytes()
    assert main(["assign", str(roi_path), ZOOM_FRAME_ID, str(image)]) == 1
    assert roi_path.read_bytes() == roi_before


def test_shared_asset_stays_on_the_other_frame(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    replacement = tmp_path / "square.png"
    Image.new("RGB", (200, 200), (20, 140, 80)).save(replacement, format="PNG")
    project = build_two_image_project(image, comparison)
    for binding in project.slide.bindings:
        if binding.element_id == FRAME_COMPARE_ID:
            binding.asset_id = "asset-overall"
    project_path = tmp_path / "sample_a.project.json"
    save_project(project, project_path)

    assert main(["assign", str(project_path), FRAME_COMPARE_ID, str(replacement)]) == 0

    loaded = load_project(project_path)
    overall = next(item for item in loaded.slide.bindings if item.element_id == FRAME_OVERALL_ID)
    compare = next(item for item in loaded.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    shared = next(item for item in loaded.assets if item.id == "asset-overall")
    assert overall.asset_id == "asset-overall"
    assert compare.asset_id != "asset-overall"
    assert Path(shared.path) == image.resolve()
    assert shared.width_px == 800
    assigned = next(item for item in loaded.assets if item.id == compare.asset_id)
    assert Path(assigned.path) == replacement.resolve()
    assert assigned.width_px == 200


def test_unassign_clears_one_frame_and_keeps_the_file(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(build_two_image_project(overall, comparison), project_path)

    assert (
        main(
            [
                "unassign",
                str(project_path),
                FRAME_COMPARE_ID,
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    loaded = load_project(project_path)
    compare_binding = next(item for item in loaded.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    overall_binding = next(item for item in loaded.slide.bindings if item.element_id == FRAME_OVERALL_ID)
    assert compare_binding.asset_id is None
    assert overall_binding.asset_id == "asset-overall"
    kept = next(item for item in loaded.assets if item.id == "asset-compare")
    assert Path(kept.path) == comparison.resolve()
    result = load_layout_result(layout_path)
    compare_image = next(item for item in result.elements if item.element_id == FRAME_COMPARE_ID)
    overall_image = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert compare_image.content_rect is None
    assert compare_image.asset_path is None
    assert any(item.code == "unassigned_image" and item.element_id == FRAME_COMPARE_ID for item in result.violations)
    assert_assigned_rect(overall_image.content_rect, 36, 106.5, 438, 219)
    assert caption.text == DEFAULT_CAPTION
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    blobs = [picture.image.blob for picture in pictures]
    assert overall_bytes in blobs
    assert comparison_bytes not in blobs
    cleared = project_path.read_bytes()
    assert main(["unassign", str(project_path), FRAME_COMPARE_ID]) == 1
    assert project_path.read_bytes() == cleared

    assert main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    restored = load_project(project_path)
    restored_binding = next(item for item in restored.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    assert restored_binding.asset_id == "asset-compare"


def test_unassign_keeps_roi_coordinates(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    save_project(build_roi_project(image, (800, 400)), project_path)

    assert main(["unassign", str(project_path), FRAME_OVERALL_ID, "--layout", str(layout_path)]) == 0

    assert image.read_bytes() == before
    loaded = load_project(project_path)
    roi = loaded.slide.rois[0]
    assert roi.x == pytest.approx(0.1)
    assert roi.width == pytest.approx(0.2)
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    asset = next(item for item in loaded.assets if item.id == "asset-overall")
    assert Path(asset.path) == image.resolve()
    result = load_layout_result(layout_path)
    assert any(item.code == "unassigned_image" for item in result.violations)
    assert any(item.code == "roi_unmapped" and item.element_id == ROI_ID for item in result.violations)
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    assert zoom.content_rect is None


def test_rejected_unassign_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    project = build_two_image_project(image, comparison)
    project.slide.bindings.append(Binding(element_id=FRAME_COMPARE_ID, asset_id="asset-compare"))
    project_path = tmp_path / "sample_a.project.json"
    save_project(project, project_path)
    before = project_path.read_bytes()
    assert main(["unassign", str(project_path), FRAME_COMPARE_ID]) == 1
    assert main(["unassign", str(project_path), "missing-frame"]) == 1
    assert project_path.read_bytes() == before

    roi_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), roi_path)
    roi_before = roi_path.read_bytes()
    assert main(["unassign", str(roi_path), ZOOM_FRAME_ID]) == 1
    assert roi_path.read_bytes() == roi_before


def test_unassign_leaves_a_shared_asset_on_the_other_frame(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    before = image.read_bytes()
    project = build_two_image_project(image, comparison)
    for binding in project.slide.bindings:
        if binding.element_id == FRAME_COMPARE_ID:
            binding.asset_id = "asset-overall"
    project_path = tmp_path / "sample_a.project.json"
    save_project(project, project_path)

    assert main(["unassign", str(project_path), FRAME_COMPARE_ID]) == 0

    assert image.read_bytes() == before
    loaded = load_project(project_path)
    overall = next(item for item in loaded.slide.bindings if item.element_id == FRAME_OVERALL_ID)
    compare = next(item for item in loaded.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    shared = next(item for item in loaded.assets if item.id == "asset-overall")
    assert overall.asset_id == "asset-overall"
    assert compare.asset_id is None
    assert Path(shared.path) == image.resolve()
    assert shared.width_px == 800


def test_unshare_one_frame_keeps_the_image_on_the_other(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    project = build_two_image_project(overall, comparison)
    project.slide.rois.append(
        Roi(
            id="roi-1",
            name="ROI",
            source_element_id=FRAME_OVERALL_ID,
            x=0.1,
            y=0.2,
            width=0.2,
            height=0.6,
        )
    )
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(project, project_path)
    assert main(["share-asset", str(project_path), FRAME_COMPARE_ID, "asset-overall"]) == 0

    assert (
        main(
            [
                "unassign",
                str(project_path),
                FRAME_COMPARE_ID,
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    loaded = load_project(project_path)
    bindings = {item.element_id: item.asset_id for item in loaded.slide.bindings}
    assert bindings[FRAME_OVERALL_ID] == "asset-overall"
    assert bindings[FRAME_COMPARE_ID] is None
    kept = next(item for item in loaded.assets if item.id == "asset-overall")
    assert kept.width_px == 800
    assert kept.height_px == 400
    assert any(item.id == "asset-compare" for item in loaded.assets)
    roi = loaded.slide.rois[0]
    assert roi.x == pytest.approx(0.1)
    assert roi.y == pytest.approx(0.2)
    assert roi.width == pytest.approx(0.2)
    assert roi.height == pytest.approx(0.6)
    assert roi.source_element_id == FRAME_OVERALL_ID
    result = load_layout_result(layout_path)
    overall_image = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    compare_image = next(item for item in result.elements if item.element_id == FRAME_COMPARE_ID)
    assert_assigned_rect(overall_image.content_rect, 36, 106.5, 438, 219)
    assert compare_image.content_rect is None
    assert any(item.code == "unassigned_image" and item.element_id == FRAME_COMPARE_ID for item in result.violations)
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    assert [picture.image.blob for picture in pictures] == [overall_bytes]

    assert main(["undo", str(project_path)]) == 0
    restored = load_project(project_path)
    restored_bindings = {item.element_id: item.asset_id for item in restored.slide.bindings}
    assert restored_bindings[FRAME_OVERALL_ID] == "asset-overall"
    assert restored_bindings[FRAME_COMPARE_ID] == "asset-overall"


def assert_assigned_rect(actual, x: float, y: float, width: float, height: float) -> None:
    assert actual is not None
    assert actual.x == pytest.approx(x)
    assert actual.y == pytest.approx(y)
    assert actual.width == pytest.approx(width)
    assert actual.height == pytest.approx(height)


def test_register_folder_adds_images_without_assigning(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    overall_bytes = overall.read_bytes()
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    extra_bytes = extra.read_bytes()
    (folder / "notes.txt").write_text("not an image", encoding="utf-8")
    nested = folder / "nested"
    nested.mkdir()
    Image.new("RGB", (8, 8), (1, 2, 3)).save(nested / "deep.png", format="PNG")
    deeper = nested / "more"
    deeper.mkdir()
    Image.new("RGB", (4, 4), (4, 5, 6)).save(deeper / "deep.png", format="PNG")
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    save_project(build_two_image_project(overall, comparison), project_path)
    before_bindings = [
        (item.element_id, item.asset_id) for item in load_project(project_path).slide.bindings
    ]

    assert (
        main(
            [
                "register-folder",
                str(project_path),
                str(folder),
                "--layout",
                str(layout_path),
            ]
        )
        == 0
    )

    assert capsys.readouterr().out.strip() == "registered 3 skipped 1"
    assert overall.read_bytes() == overall_bytes
    assert extra.read_bytes() == extra_bytes
    stored = project_path.read_text(encoding="utf-8")
    assert "extra.png" in stored
    assert str(extra.resolve()) not in stored
    loaded = load_project(project_path)
    assert [(item.element_id, item.asset_id) for item in loaded.slide.bindings] == before_bindings
    added = [item for item in loaded.assets if item.display_name == "extra"]
    assert len(added) == 1
    assert added[0].width_px == 32
    assert added[0].height_px == 16
    assert Path(added[0].path) == extra.resolve()
    nested_asset = next(item for item in loaded.assets if item.display_name == "nested/deep")
    assert nested_asset.width_px == 8
    assert nested_asset.height_px == 8
    assert Path(nested_asset.path) == (nested / "deep.png").resolve()
    deeper_asset = next(item for item in loaded.assets if item.display_name == "nested/more/deep")
    assert Path(deeper_asset.path) == (deeper / "deep.png").resolve()
    result = load_layout_result(layout_path)
    overall_image = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert_assigned_rect(overall_image.content_rect, 36, 106.5, 438, 219)
    assert caption.text == DEFAULT_CAPTION

    registered = project_path.read_bytes()
    assert main(["register-folder", str(project_path), str(folder)]) == 0
    assert capsys.readouterr().out.strip() == "registered 0 skipped 1"
    assert project_path.read_bytes() == registered


def test_rejected_folder_registration_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    project_path = tmp_path / "sample_a.project.json"
    save_project(build_two_image_project(image, comparison), project_path)
    before = project_path.read_bytes()
    empty = tmp_path / "empty"
    empty.mkdir()

    assert main(["register-folder", str(project_path), str(tmp_path / "missing")]) == 1
    assert main(["register-folder", str(project_path), str(image)]) == 1
    assert project_path.read_bytes() == before
    assert main(["register-folder", str(project_path), str(empty)]) == 0
    assert project_path.read_bytes() == before


def test_assign_registered_asset_switches_one_frame(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    extra_bytes = extra.read_bytes()
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(build_two_image_project(overall, comparison), project_path)
    assert main(["register-folder", str(project_path), str(folder)]) == 0
    registered = load_project(project_path)
    extra_asset = next(item for item in registered.assets if item.display_name == "extra")
    assert extra_asset.id == "asset-1"
    registered_path = extra_asset.path
    asset_count = len(registered.assets)

    assert (
        main(
            [
                "assign-asset",
                str(project_path),
                FRAME_COMPARE_ID,
                extra_asset.id,
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    assert extra.read_bytes() == extra_bytes
    stored = project_path.read_text(encoding="utf-8")
    assert "extra.png" in stored
    assert str(extra.resolve()) not in stored
    loaded = load_project(project_path)
    assert len(loaded.assets) == asset_count
    compare = next(item for item in loaded.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    overall_binding = next(item for item in loaded.slide.bindings if item.element_id == FRAME_OVERALL_ID)
    assert compare.asset_id == extra_asset.id
    assert overall_binding.asset_id == "asset-overall"
    kept = next(item for item in loaded.assets if item.id == extra_asset.id)
    assert kept.path == registered_path
    assert kept.width_px == 32
    assert kept.height_px == 16
    assert kept.display_name == "extra"
    previous = next(item for item in loaded.assets if item.id == "asset-compare")
    assert Path(previous.path) == comparison.resolve()
    result = load_layout_result(layout_path)
    compare_image = next(item for item in result.elements if item.element_id == FRAME_COMPARE_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert_assigned_rect(compare_image.content_rect, 486, 106.5, 438, 219)
    assert caption.text == DEFAULT_CAPTION
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    blobs = [picture.image.blob for picture in pictures]
    assert extra_bytes in blobs
    assert overall_bytes in blobs
    assert comparison_bytes not in blobs

    assert main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    restored = load_project(project_path)
    restored_compare = next(item for item in restored.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    assert restored_compare.asset_id == "asset-compare"

    assert main(["unassign", str(project_path), FRAME_COMPARE_ID]) == 0
    assert main(["assign-asset", str(project_path), FRAME_COMPARE_ID, extra_asset.id]) == 0
    rebound = load_project(project_path)
    compare_bindings = [item for item in rebound.slide.bindings if item.element_id == FRAME_COMPARE_ID]
    assert len(compare_bindings) == 1
    assert compare_bindings[0].asset_id == extra_asset.id


def test_assign_registered_asset_keeps_roi_coordinates(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    extra_bytes = extra.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["register-folder", str(project_path), str(folder)]) == 0
    extra_id = next(item.id for item in load_project(project_path).assets if item.display_name == "extra")

    assert main(["assign-asset", str(project_path), FRAME_OVERALL_ID, extra_id]) == 0

    assert image.read_bytes() == before
    assert extra.read_bytes() == extra_bytes
    roi = load_project(project_path).slide.rois[0]
    assert roi.x == pytest.approx(0.1)
    assert roi.y == pytest.approx(0.2)
    assert roi.width == pytest.approx(0.2)
    assert roi.height == pytest.approx(0.6)
    assert roi.coord_space == CoordSpace.NORMALIZED
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    assert roi.note == ""


def test_rejected_registered_asset_assignment_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    project_path = tmp_path / "sample_a.project.json"
    save_project(build_two_image_project(image, comparison), project_path)
    assert main(["register-folder", str(project_path), str(folder)]) == 0
    extra_id = next(item.id for item in load_project(project_path).assets if item.display_name == "extra")
    before = project_path.read_bytes()
    extra.unlink()

    assert main(["assign-asset", str(project_path), FRAME_COMPARE_ID, extra_id]) == 1
    extra_bytes_path = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra_bytes_path, format="PNG")
    assert main(["assign-asset", str(project_path), FRAME_COMPARE_ID, "asset-overall"]) == 1
    assert main(["assign-asset", str(project_path), FRAME_COMPARE_ID, "asset-compare"]) == 1
    assert main(["assign-asset", str(project_path), FRAME_COMPARE_ID, "missing-asset"]) == 1
    assert main(["assign-asset", str(project_path), "missing-frame", extra_id]) == 1
    assert project_path.read_bytes() == before

    roi_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), roi_path)
    assert main(["register-folder", str(roi_path), str(folder)]) == 0
    roi_extra = next(item.id for item in load_project(roi_path).assets if item.display_name == "extra")
    roi_before = roi_path.read_bytes()
    assert main(["assign-asset", str(roi_path), ZOOM_FRAME_ID, roi_extra]) == 1
    assert roi_path.read_bytes() == roi_before

    conflict = build_two_image_project(image, comparison)
    conflict.slide.bindings.append(Binding(element_id=FRAME_COMPARE_ID, asset_id="asset-compare"))
    conflict_path = tmp_path / "conflict.project.json"
    save_project(conflict, conflict_path)
    assert main(["register-folder", str(conflict_path), str(folder)]) == 0
    conflict_extra = next(item.id for item in load_project(conflict_path).assets if item.display_name == "extra")
    conflict_before = conflict_path.read_bytes()
    assert main(["assign-asset", str(conflict_path), FRAME_COMPARE_ID, conflict_extra]) == 1
    assert conflict_path.read_bytes() == conflict_before


def test_remove_unused_asset_keeps_the_file_and_assigned_frames(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    extra_bytes = extra.read_bytes()
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(build_two_image_project(overall, comparison), project_path)
    assert main(["register-folder", str(project_path), str(folder)]) == 0
    before_bindings = [
        (item.element_id, item.asset_id) for item in load_project(project_path).slide.bindings
    ]

    assert (
        main(
            [
                "remove-asset",
                str(project_path),
                "asset-1",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert extra.read_bytes() == extra_bytes
    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    loaded = load_project(project_path)
    assert [item.id for item in loaded.assets] == ["asset-overall", "asset-compare"]
    assert [(item.element_id, item.asset_id) for item in loaded.slide.bindings] == before_bindings
    result = load_layout_result(layout_path)
    overall_image = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert_assigned_rect(overall_image.content_rect, 36, 106.5, 438, 219)
    assert caption.text == DEFAULT_CAPTION
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    blobs = [picture.image.blob for picture in pictures]
    assert overall_bytes in blobs
    assert comparison_bytes in blobs
    assert extra_bytes not in blobs

    assert main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    restored = load_project(project_path)
    assert any(item.id == "asset-1" and item.display_name == "extra" for item in restored.assets)

    assert main(["unassign", str(project_path), FRAME_COMPARE_ID]) == 0
    assert main(["remove-asset", str(project_path), "asset-compare", "--layout", str(layout_path)]) == 0
    cleared = load_project(project_path)
    assert comparison.read_bytes() == comparison_bytes
    assert all(item.id != "asset-compare" for item in cleared.assets)
    compare = next(item for item in cleared.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    overall_binding = next(item for item in cleared.slide.bindings if item.element_id == FRAME_OVERALL_ID)
    assert compare.asset_id is None
    assert overall_binding.asset_id == "asset-overall"
    cleared_layout = load_layout_result(layout_path)
    cleared_overall = next(item for item in cleared_layout.elements if item.element_id == FRAME_OVERALL_ID)
    assert_assigned_rect(cleared_overall.content_rect, 36, 106.5, 438, 219)


def test_remove_unused_asset_keeps_roi_coordinates(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    before = image.read_bytes()
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    extra_bytes = extra.read_bytes()
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main(["register-folder", str(project_path), str(folder)]) == 0

    assert main(["remove-asset", str(project_path), "asset-1"]) == 0

    assert image.read_bytes() == before
    assert extra.read_bytes() == extra_bytes
    loaded = load_project(project_path)
    assert [item.id for item in loaded.assets] == ["asset-overall"]
    roi = loaded.slide.rois[0]
    assert roi.x == pytest.approx(0.1)
    assert roi.y == pytest.approx(0.2)
    assert roi.width == pytest.approx(0.2)
    assert roi.height == pytest.approx(0.6)
    assert roi.coord_space == CoordSpace.NORMALIZED
    assert roi.zoom_element_id == ZOOM_FRAME_ID
    assert roi.note == ""


def test_rejected_asset_removal_does_not_change_the_project(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    image_bytes = image.read_bytes()
    project_path = tmp_path / "sample_a.project.json"
    save_project(build_two_image_project(image, comparison), project_path)
    before = project_path.read_bytes()

    assert main(["remove-asset", str(project_path), "asset-overall"]) == 1
    assert main(["remove-asset", str(project_path), "asset-compare"]) == 1
    assert main(["remove-asset", str(project_path), "missing-asset"]) == 1
    assert project_path.read_bytes() == before
    assert image.read_bytes() == image_bytes


def test_share_registered_asset_uses_one_image_on_two_frames(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    pptx_path = tmp_path / "sample_a.pptx"
    save_project(build_two_image_project(overall, comparison), project_path)
    before = load_project(project_path)
    overall_asset = next(item for item in before.assets if item.id == "asset-overall")
    compare_asset = next(item for item in before.assets if item.id == "asset-compare")

    assert (
        main(
            [
                "share-asset",
                str(project_path),
                FRAME_COMPARE_ID,
                "asset-overall",
                "--layout",
                str(layout_path),
                "--pptx",
                str(pptx_path),
            ]
        )
        == 0
    )

    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    loaded = load_project(project_path)
    assert len(loaded.assets) == 2
    kept_overall = next(item for item in loaded.assets if item.id == "asset-overall")
    kept_compare = next(item for item in loaded.assets if item.id == "asset-compare")
    assert kept_overall.path == overall_asset.path
    assert kept_overall.width_px == overall_asset.width_px
    assert kept_overall.height_px == overall_asset.height_px
    assert kept_overall.display_name == overall_asset.display_name
    assert kept_compare.path == compare_asset.path
    assert kept_compare.width_px == 400
    assert kept_compare.height_px == 800
    bindings = {item.element_id: item.asset_id for item in loaded.slide.bindings}
    assert bindings[FRAME_OVERALL_ID] == "asset-overall"
    assert bindings[FRAME_COMPARE_ID] == "asset-overall"
    result = load_layout_result(layout_path)
    overall_image = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    compare_image = next(item for item in result.elements if item.element_id == FRAME_COMPARE_ID)
    caption = next(item for item in result.elements if item.kind == "text")
    assert_assigned_rect(overall_image.content_rect, 36, 106.5, 438, 219)
    assert_assigned_rect(compare_image.content_rect, 486, 106.5, 438, 219)
    assert caption.text == DEFAULT_CAPTION
    pictures = [
        shape
        for shape in Presentation(pptx_path).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.PICTURE
    ]
    blobs = [picture.image.blob for picture in pictures]
    assert blobs == [overall_bytes, overall_bytes]
    assert comparison_bytes not in blobs

    assert main(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)]) == 0
    restored = load_project(project_path)
    restored_compare = next(item for item in restored.slide.bindings if item.element_id == FRAME_COMPARE_ID)
    assert restored_compare.asset_id == "asset-compare"

    assert main(["unassign", str(project_path), FRAME_COMPARE_ID]) == 0
    assert main(["share-asset", str(project_path), FRAME_COMPARE_ID, "asset-overall"]) == 0
    shared = load_project(project_path)
    compare_bindings = [item for item in shared.slide.bindings if item.element_id == FRAME_COMPARE_ID]
    assert len(compare_bindings) == 1
    assert compare_bindings[0].asset_id == "asset-overall"
    assert comparison.read_bytes() == comparison_bytes


def test_share_registered_asset_keeps_roi_coordinates(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    overall_bytes = overall.read_bytes()
    comparison_bytes = comparison.read_bytes()
    project = build_two_image_project(overall, comparison)
    project.slide.rois.append(
        Roi(
            id="roi-1",
            name="ROI",
            source_element_id=FRAME_OVERALL_ID,
            x=0.1,
            y=0.2,
            width=0.2,
            height=0.6,
        )
    )
    project_path = tmp_path / "sample_a.project.json"
    save_project(project, project_path)

    assert main(["share-asset", str(project_path), FRAME_OVERALL_ID, "asset-compare"]) == 0

    assert overall.read_bytes() == overall_bytes
    assert comparison.read_bytes() == comparison_bytes
    loaded = load_project(project_path)
    bindings = {item.element_id: item.asset_id for item in loaded.slide.bindings}
    assert bindings[FRAME_OVERALL_ID] == "asset-compare"
    assert bindings[FRAME_COMPARE_ID] == "asset-compare"
    assert any(item.id == "asset-overall" for item in loaded.assets)
    roi = loaded.slide.rois[0]
    assert roi.x == pytest.approx(0.1)
    assert roi.y == pytest.approx(0.2)
    assert roi.width == pytest.approx(0.2)
    assert roi.height == pytest.approx(0.6)
    assert roi.coord_space == CoordSpace.NORMALIZED
    assert roi.zoom_element_id is None
    assert roi.note == ""


def test_rejected_asset_share_does_not_change_the_project(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    overall_bytes = overall.read_bytes()
    folder = tmp_path / "incoming"
    folder.mkdir()
    extra = folder / "extra.png"
    Image.new("RGB", (32, 16), (10, 20, 30)).save(extra, format="PNG")
    project_path = tmp_path / "sample_a.project.json"
    save_project(build_two_image_project(overall, comparison), project_path)
    assert main(["register-folder", str(project_path), str(folder)]) == 0
    before = project_path.read_bytes()

    assert main(["share-asset", str(project_path), FRAME_COMPARE_ID, "asset-compare"]) == 1
    assert main(["share-asset", str(project_path), FRAME_COMPARE_ID, "asset-1"]) == 1
    assert main(["share-asset", str(project_path), FRAME_COMPARE_ID, "missing-asset"]) == 1
    assert main(["share-asset", str(project_path), "missing-frame", "asset-overall"]) == 1
    overall.unlink()
    assert main(["share-asset", str(project_path), FRAME_COMPARE_ID, "asset-overall"]) == 1
    assert project_path.read_bytes() == before
    Image.new("RGB", (800, 400), (47, 111, 176)).save(overall, format="PNG")

    roi_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(overall, (800, 400)), roi_path)
    roi_before = roi_path.read_bytes()
    assert main(["share-asset", str(roi_path), ZOOM_FRAME_ID, "asset-overall"]) == 1
    assert roi_path.read_bytes() == roi_before

    conflict = build_two_image_project(overall, comparison)
    conflict.slide.bindings.append(Binding(element_id=FRAME_COMPARE_ID, asset_id="asset-compare"))
    conflict_path = tmp_path / "conflict.project.json"
    save_project(conflict, conflict_path)
    conflict_before = conflict_path.read_bytes()
    assert main(["share-asset", str(conflict_path), FRAME_COMPARE_ID, "asset-overall"]) == 1
    assert conflict_path.read_bytes() == conflict_before


def test_stale_pptx_export_does_not_replace_a_newer_save(tmp_path: Path):
    from smart_report_builder.project_store import save_layout_result
    from smart_report_builder.roi_edit import _claim_pptx_seq, _export_pptx

    image = _write_png(tmp_path / "overall.png")
    layout_path = tmp_path / "layout.json"
    save_layout_result(layout_slide(build_roi_project(image, (800, 400))), layout_path)
    pptx_path = tmp_path / "report.pptx"
    pptx_path.write_bytes(b"newer")
    older = _claim_pptx_seq(pptx_path)
    current = _claim_pptx_seq(pptx_path)

    assert _export_pptx([str(layout_path), str(pptx_path), str(older)]) == 0
    assert pptx_path.read_bytes() == b"newer"
    assert _export_pptx([str(layout_path), str(pptx_path), str(current)]) == 0
    assert pptx_path.read_bytes().startswith(b"PK")


def test_layout_notify_returns_without_writing_pptx(tmp_path: Path, monkeypatch, capsys):
    import time

    monkeypatch.setenv("SMART_REPORT_LAYOUT_NOTIFY", "1")
    monkeypatch.setattr(
        "smart_report_builder.roi_edit.write_pptx_slides",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("pptx")),
    )
    image = _write_png(tmp_path / "overall.png")
    project_path = tmp_path / "sample_roi.project.json"
    layout_path = tmp_path / "sample_roi.layout.json"
    pptx_path = tmp_path / "sample_roi.pptx"
    save_project(build_roi_project(image, (800, 400)), project_path)

    code = main(
        [
            str(project_path),
            ROI_ID,
            "0.25",
            "0.10",
            "0.40",
            "0.40",
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )

    captured = capsys.readouterr()
    assert code == 0
    assert f"LAYOUT_READY\t{layout_path}" in captured.out
    assert f"updated {ROI_ID}" in captured.out
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and not pptx_path.is_file():
        time.sleep(0.05)
    assert pptx_path.is_file()


def test_arrange_zooms_places_one_enlarged_image_per_roi(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    project = build_two_image_project(overall, comparison)
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    save_project(project, project_path)
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.10", "0.20", "0.20", "0.30"]) == 0
    assert main(["create", str(project_path), FRAME_OVERALL_ID, "0.50", "0.10", "0.25", "0.40"]) == 0
    before = load_project(project_path)
    rectangles = [(roi.x, roi.y, roi.width, roi.height) for roi in before.slide.rois]

    code = main(
        [
            "arrange-zooms",
            str(project_path),
            "--arrangement",
            "horizontal",
            "--layout",
            str(layout_path),
        ]
    )

    assert code == 0
    loaded = load_project(project_path)
    assert [(roi.x, roi.y, roi.width, roi.height) for roi in loaded.slide.rois] == rectangles
    images = loaded.content_master.root.children[0]
    zooms = loaded.content_master.root.children[1]
    assert isinstance(images, StackNode)
    assert [item.id for item in images.children] == [FRAME_OVERALL_ID, FRAME_COMPARE_ID]
    assert isinstance(zooms, StackNode)
    assert zooms.direction == StackDirection.HORIZONTAL
    assert [item.id for item in zooms.children] == [roi.zoom_element_id for roi in loaded.slide.rois]
    result = load_layout_result(layout_path)
    placed = [item for item in result.elements if item.element_id in {child.id for child in zooms.children}]
    assert len(placed) == 2
    assert placed[0].frame.y == pytest.approx(placed[1].frame.y)
    assert placed[0].frame.x < placed[1].frame.x
    assert placed[0].crop is not None
    assert placed[0].crop.x == pytest.approx(0.10)
    assert placed[1].crop is not None
    assert placed[1].crop.x == pytest.approx(0.50)
    caption = next(item for item in loaded.content_master.root.children if isinstance(item, TextNode))
    assert caption.text == DEFAULT_CAPTION


def test_arrange_zooms_reuses_a_frame_and_can_stack_or_grid(tmp_path: Path):
    image = _write_png(tmp_path / "overall.png")
    project = build_roi_project(image, (800, 400))
    project.slide.rois.append(
        Roi(
            id="roi-2",
            name="ROI 2",
            source_element_id=FRAME_OVERALL_ID,
            zoom_element_id=ZOOM_FRAME_ID,
            x=0.4,
            y=0.1,
            width=0.3,
            height=0.4,
        )
    )
    project_path = tmp_path / "sample_roi.project.json"
    save_project(project, project_path)

    assert main(["arrange-zooms", str(project_path), "--arrangement", "vertical"]) == 0
    loaded = load_project(project_path)
    assert loaded.slide.rois[0].zoom_element_id == ZOOM_FRAME_ID
    assert loaded.slide.rois[1].zoom_element_id != ZOOM_FRAME_ID
    zooms = loaded.content_master.root.children[1]
    assert isinstance(zooms, StackNode)
    assert zooms.direction == StackDirection.VERTICAL
    assert len(zooms.children) == 2
    result = layout_slide(loaded)
    placed = [item for item in result.elements if item.fit_mode == "roi" and item.kind == "image_frame"]
    assert placed[0].frame.x == pytest.approx(placed[1].frame.x)
    assert placed[0].frame.y < placed[1].frame.y

    assert main(["arrange-zooms", str(project_path), "--arrangement", "grid"]) == 0
    gridded = load_project(project_path)
    block = gridded.content_master.root.children[1]
    assert isinstance(block, GridNode)
    assert block.columns == 2
    assert [item.id for item in block.children] == [roi.zoom_element_id for roi in gridded.slide.rois]
    assert len(gridded.slide.rois) == 2


def test_arrange_zooms_rejects_a_project_without_rois(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    project_path = tmp_path / "sample_a.project.json"
    save_project(build_two_image_project(overall, comparison), project_path)
    before = project_path.read_bytes()

    assert main(["arrange-zooms", str(project_path)]) == 1
    assert main(["arrange-zooms", str(project_path), "--arrangement", "diagonal"]) == 1
    assert project_path.read_bytes() == before


def _assert_rect(actual, expected) -> None:
    assert actual.x == pytest.approx(expected.x)
    assert actual.y == pytest.approx(expected.y)
    assert actual.width == pytest.approx(expected.width)
    assert actual.height == pytest.approx(expected.height)


def test_each_image_frame_can_change_width_and_height_on_its_own(tmp_path: Path):
    overall = _write_png(tmp_path / "overall.png")
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (400, 800), (180, 90, 40)).save(comparison, format="PNG")
    project = build_two_image_project(overall, comparison)
    project_path = tmp_path / "sample_a.project.json"
    layout_path = tmp_path / "sample_a.layout.json"
    save_project(project, project_path)
    before = layout_slide(project)
    before_overall = next(item for item in before.elements if item.element_id == FRAME_OVERALL_ID)
    before_compare = next(item for item in before.elements if item.element_id == FRAME_COMPARE_ID)
    group = before_overall.group_frame
    assert group is not None

    assert (
        main(
            [
                "resize-frame",
                str(project_path),
                FRAME_OVERALL_ID,
                "0",
                "0",
                "0.35",
                "0.45",
                "--layout",
                str(layout_path),
            ]
        )
        == 0
    )

    result = load_layout_result(layout_path)
    resized = next(item for item in result.elements if item.element_id == FRAME_OVERALL_ID)
    untouched = next(item for item in result.elements if item.element_id == FRAME_COMPARE_ID)
    _assert_rect(untouched.frame, before_compare.frame)
    assert resized.frame.x == pytest.approx(group.x)
    assert resized.frame.y == pytest.approx(group.y)
    assert resized.frame.width == pytest.approx(group.width * 0.35)
    assert resized.frame.height == pytest.approx(group.height * 0.45)
    assert resized.content_rect is not None
    assert resized.content_rect.x >= resized.frame.x - 0.01
    assert resized.content_rect.y >= resized.frame.y - 0.01
    assert resized.content_rect.x + resized.content_rect.width <= resized.frame.x + resized.frame.width + 0.01
    assert resized.content_rect.y + resized.content_rect.height <= resized.frame.y + resized.frame.height + 0.01
    stored = load_project(project_path)
    images = stored.content_master.root.children[0]
    overall_node = next(item for item in images.children if item.id == FRAME_OVERALL_ID)
    assert overall_node.free_rect is not None
    assert overall_node.free_rect.width == pytest.approx(0.35)
    assert overall_node.free_rect.height == pytest.approx(0.45)

    assert (
        main(
            [
                "resize-frame",
                str(project_path),
                FRAME_OVERALL_ID,
                "0.05",
                "0.1",
                "0.4",
                "0.5",
                "--layout",
                str(layout_path),
            ]
        )
        == 0
    )
    again = load_layout_result(layout_path)
    still = next(item for item in again.elements if item.element_id == FRAME_COMPARE_ID)
    _assert_rect(still.frame, before_compare.frame)
    kept = project_path.read_bytes()
    assert main(["resize-frame", str(project_path), FRAME_OVERALL_ID, "0", "0", "0.01", "0.5"]) == 1
    assert project_path.read_bytes() == kept


def test_zoom_link_is_chosen_only_when_one_frame_is_free():
    assert zoom_link_label(["frame-zoom"], set()) == "frame-zoom"
    assert zoom_link_label(["frame-zoom"], {"frame-zoom"}) == "-"
    assert zoom_link_label(["frame-zoom", "frame-zoom-b"], set()) == "ambiguous"


def _zoom_rect(result):
    zoom = next(item for item in result.elements if item.element_id == ZOOM_FRAME_ID)
    return zoom.content_rect


def _write_png(path: Path) -> Path:
    Image.new("RGB", (800, 400), (47, 111, 176)).save(path, format="PNG")
    return path
