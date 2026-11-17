import zipfile

import pytest
from PIL import Image
from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE

from smart_report_builder.demo import DEFAULT_CAPTION, build_roi_project, build_two_image_project
from smart_report_builder.layout import layout_slide
from smart_report_builder.pptx_writer import write_pptx
from smart_report_builder.units import pt_to_emu


def test_assigned_slide_exports_separate_editable_objects(tmp_path):
    overall, comparison = _write_pair(tmp_path)
    before = {path: path.read_bytes() for path in (overall, comparison)}
    project = build_two_image_project(overall, comparison, (800, 400), (400, 800))
    result = layout_slide(project)
    destination = tmp_path / "sample.pptx"
    write_pptx(result, destination)

    for path, blob in before.items():
        assert path.read_bytes() == blob

    presentation = Presentation(destination)
    assert presentation.slide_width == pt_to_emu(result.slide_width_pt)
    assert presentation.slide_height == pt_to_emu(result.slide_height_pt)
    slide = presentation.slides[0]
    shapes = list(slide.shapes)
    assert len(shapes) == 5
    assert _count(shapes, MSO_SHAPE_TYPE.PICTURE) == 2
    assert _count(shapes, MSO_SHAPE_TYPE.AUTO_SHAPE) == 2
    assert _count(shapes, MSO_SHAPE_TYPE.TEXT_BOX) == 1

    by_name = {shape.name: shape for shape in shapes}
    _assert_emu(by_name["全体画像"], result.elements[0].frame)
    _assert_emu(by_name["比較画像"], result.elements[1].frame)
    _assert_emu(by_name["全体画像（画像）"], result.elements[0].content_rect)
    _assert_emu(by_name["比較画像（画像）"], result.elements[1].content_rect)
    _assert_emu(by_name["説明"], result.elements[2].frame)
    assert by_name["全体画像（画像）"].top == pt_to_emu(106.5)
    assert by_name["全体画像（画像）"].height != by_name["全体画像"].height
    assert by_name["比較画像（画像）"].width != by_name["比較画像"].width
    assert by_name["説明"].text_frame.text == DEFAULT_CAPTION
    caption_frame = by_name["説明"].text_frame
    assert caption_frame.margin_left == 0
    assert caption_frame.margin_top == 0
    assert caption_frame.margin_right == 0
    assert caption_frame.margin_bottom == 0
    for shape in shapes:
        if shape.shape_type == MSO_SHAPE_TYPE.AUTO_SHAPE:
            assert shape.text_frame.text == ""

    xml = slide._element.xml
    assert "<p:pic" in xml
    assert 'txBox="1"' in xml
    assert DEFAULT_CAPTION in xml
    assert "p:sp" in xml

    with zipfile.ZipFile(destination) as archive:
        blobs = [
            archive.read(name)
            for name in archive.namelist()
            if name.startswith("ppt/media/")
        ]
    assert before[overall] in blobs
    assert before[comparison] in blobs


def test_unassigned_master_exports_frames_and_text_without_pictures(tmp_path):
    result = layout_slide(build_two_image_project(assign_images=False))
    destination = tmp_path / "empty.pptx"
    write_pptx(result, destination)

    slide = Presentation(destination).slides[0]
    shapes = list(slide.shapes)
    assert _count(shapes, MSO_SHAPE_TYPE.PICTURE) == 0
    assert _count(shapes, MSO_SHAPE_TYPE.AUTO_SHAPE) == 2
    assert _count(shapes, MSO_SHAPE_TYPE.TEXT_BOX) == 1
    assert len(shapes) == 3
    text_box = next(shape for shape in shapes if shape.shape_type == MSO_SHAPE_TYPE.TEXT_BOX)
    assert text_box.text_frame.text == DEFAULT_CAPTION
    assert "<p:pic" not in slide._element.xml


def test_overflowing_text_is_exported_in_full(tmp_path):
    overall, comparison = _write_pair(tmp_path)
    project = build_two_image_project(
        overall,
        comparison,
        (800, 400),
        (400, 800),
        text_height_pt=1000,
    )
    result = layout_slide(project)
    destination = tmp_path / "overflow.pptx"
    write_pptx(result, destination)

    text_box = next(
        shape
        for shape in Presentation(destination).slides[0].shapes
        if shape.shape_type == MSO_SHAPE_TYPE.TEXT_BOX
    )
    assert text_box.text_frame.text == DEFAULT_CAPTION
    assert text_box.height == pt_to_emu(1000)


def test_roi_exports_an_independent_shape_and_crops_only_the_zoom(tmp_path):
    overall = tmp_path / "overall.png"
    Image.new("RGB", (800, 400), (47, 111, 176)).save(overall, format="PNG")
    original = overall.read_bytes()
    result = layout_slide(build_roi_project(overall, (800, 400)))
    destination = tmp_path / "roi.pptx"
    write_pptx(result, destination)
    assert overall.read_bytes() == original

    shapes = list(Presentation(destination).slides[0].shapes)
    assert _count(shapes, MSO_SHAPE_TYPE.PICTURE) == 2
    assert _count(shapes, MSO_SHAPE_TYPE.AUTO_SHAPE) == 3
    assert _count(shapes, MSO_SHAPE_TYPE.TEXT_BOX) == 1
    by_name = {shape.name: shape for shape in shapes}
    roi = next(element for element in result.elements if element.kind == "roi")
    zoom = next(element for element in result.elements if element.element_id == "frame-zoom")
    _assert_emu(by_name["ROI"], roi.frame)
    _assert_emu(by_name["拡大画像（画像）"], zoom.content_rect)
    assert by_name["全体画像（画像）"].crop_left == 0
    assert by_name["拡大画像（画像）"].crop_left == pytest.approx(0.1)
    assert by_name["拡大画像（画像）"].crop_top == pytest.approx(0.2)
    assert by_name["拡大画像（画像）"].crop_right == pytest.approx(0.7)
    assert by_name["拡大画像（画像）"].crop_bottom == pytest.approx(0.2)
    assert by_name["ROI"].shape_type == MSO_SHAPE_TYPE.AUTO_SHAPE
    with zipfile.ZipFile(destination) as archive:
        blobs = [archive.read(name) for name in archive.namelist() if name.startswith("ppt/media/")]
    assert original in blobs


def _write_pair(tmp_path):
    overall = tmp_path / "overall.png"
    comparison = tmp_path / "comparison.png"
    Image.new("RGB", (800, 400), (47, 111, 176)).save(overall, format="PNG")
    Image.new("RGB", (400, 800), (196, 122, 48)).save(comparison, format="PNG")
    return overall, comparison


def _count(shapes, shape_type) -> int:
    return sum(1 for shape in shapes if shape.shape_type == shape_type)


def _assert_emu(shape, rect) -> None:
    assert shape.left == pt_to_emu(rect.x)
    assert shape.top == pt_to_emu(rect.y)
    assert shape.width == pt_to_emu(rect.width)
    assert shape.height == pt_to_emu(rect.height)
