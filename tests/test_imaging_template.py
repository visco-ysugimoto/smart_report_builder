from pptx import Presentation
from pptx.util import Inches
from PIL import Image

from smart_report_builder.imaging_template import (
    APP_SHAPE_PREFIX,
    bundled_template,
    materialize_template,
    read_imaging_template,
    slide_c_name,
)
from smart_report_builder.layout import layout_slide
from smart_report_builder.project_factory import create_report
from smart_report_builder.pptx_writer import write_pptx_slides
from smart_report_builder.roi_edit import main, open_pptx_preview, set_page_title
from smart_report_builder.project_store import load_project
from smart_report_builder.units import emu_to_pt


def test_portrait_and_landscape_templates_expose_the_imaging_body():
    portrait = read_imaging_template(bundled_template("portrait"))
    landscape = read_imaging_template(bundled_template("landscape"))

    assert portrait.slide_height_pt > portrait.slide_width_pt
    assert landscape.slide_width_pt > landscape.slide_height_pt
    assert portrait.body.y > 40
    assert portrait.body.height > 400
    assert landscape.body.width > portrait.body.width
    assert portrait.title_shape_name
    assert landscape.title_font
    assert portrait.chrome
    assert any(shape.kind == "picture" for shape in landscape.chrome)


def test_imaging_pages_use_the_template_and_keep_the_other_slides(tmp_path):
    project = create_report(paper="portrait", image_count=2)
    before = bundled_template("portrait").read_bytes()
    materialize_template(project, tmp_path)
    assert bundled_template("portrait").read_bytes() == before
    assert (tmp_path / "template.pptx").read_bytes() == before

    result = layout_slide(project)
    body = project.design_master.body
    assert body is not None
    assert result.chrome_image
    assert result.title_text == "撮像画像"
    image = Image.open(result.chrome_image)
    assert image.size[0] > 100 and image.size[1] > image.size[0]
    assert len(image.getcolors(maxcolors=100000) or []) > 1
    for element in result.elements:
        if element.kind in {"image_frame", "text"}:
            assert element.frame.y >= body.y - 0.01
            assert element.frame.y + element.frame.height <= body.y + body.height + 0.01

    template = Presentation(project.design_master.template_path)
    prototype = next(index for index, slide in enumerate(template.slides) if slide_c_name(slide) == "Slide_Image1")
    following = _first_text(template.slides[prototype + 1])
    destination = tmp_path / "report.pptx"
    write_pptx_slides([result, result], destination)

    saved = Presentation(destination)
    indexes = [index for index, slide in enumerate(saved.slides) if (slide_c_name(slide) or "").startswith("Slide_Image")]
    assert indexes == [prototype, prototype + 1]
    assert _first_text(saved.slides[prototype + 2]) == following
    assert saved.slides[indexes[0]].slide_layout.name == "2_ViSCO_評価"
    assert slide_c_name(saved.slides[indexes[1]]) == "Slide_Image2"
    assert _title_text(saved.slides[indexes[0]]) == "撮像画像"
    assert any((shape.name or "").startswith(APP_SHAPE_PREFIX) for shape in saved.slides[indexes[0]].shapes)
    _assert_on_page(saved)

    saved.slides[0].shapes.add_textbox(Inches(0.4), Inches(0.4), Inches(2), Inches(0.4)).text = "手修正"
    saved.save(destination)
    first_count = _prefixed_count(Presentation(destination).slides[indexes[0]])
    write_pptx_slides([result], destination, prior_path=destination)

    again = Presentation(destination)
    assert any(shape.has_text_frame and shape.text_frame.text == "手修正" for shape in again.slides[0].shapes)
    again_indexes = [index for index, slide in enumerate(again.slides) if (slide_c_name(slide) or "").startswith("Slide_Image")]
    assert again_indexes == [prototype]
    assert _prefixed_count(again.slides[prototype]) == first_count
    assert (tmp_path / "template.pptx").read_bytes() == before


def test_opening_a_pptx_previews_it_without_changing_the_file(tmp_path):
    source = tmp_path / "template.pptx"
    source.write_bytes(bundled_template("portrait").read_bytes())
    before = source.read_bytes()
    directory = tmp_path / "template.preview"
    layout = open_pptx_preview(source, directory)

    assert source.read_bytes() == before
    assert layout == directory / "layout.json"
    assert (directory / "chrome.png").is_file()
    saved = Presentation(directory / "report.pptx")
    assert any(slide_c_name(slide) == "Slide_Image1" for slide in saved.slides)
    layout.write_text("keep", encoding="utf-8")
    assert open_pptx_preview(source, directory) == layout
    assert layout.read_text(encoding="utf-8") == "keep"


def test_opening_a_pptx_makes_one_slide_per_imaging_slide(tmp_path):
    from pptx import Presentation

    from smart_report_builder.imaging_template import duplicate_slide, imaging_slide_indexes, set_slide_c_name

    source = tmp_path / "deck.pptx"
    source.write_bytes(bundled_template("portrait").read_bytes())
    presentation = Presentation(source)
    duplicate_slide(presentation, imaging_slide_indexes(presentation)[0])
    set_slide_c_name(presentation.slides[-1], "Slide_Image2")
    presentation.save(source)
    before = source.read_bytes()

    project = load_project(open_pptx_preview(source, tmp_path / "deck.preview").parent / "project.json")
    assert source.read_bytes() == before
    assert [item.name for item in project.report_slides] == ["Slide_Image1", "Slide_Image2"]
    assert [item.layout_id for item in project.report_slides] == ["layout-1", "layout-1"]
    assert project.active_slide_id == "slide-1"


def test_new_project_command_copies_the_landscape_template(tmp_path):
    assert main(["new-project", str(tmp_path), "--paper", "landscape", "--images", "2"]) == 0
    project = load_project(tmp_path / "project.json")
    assert project.design_master.orientation == "landscape"
    assert project.slide.title == "撮像画像"
    saved = Presentation(tmp_path / "report.pptx")
    assert emu_to_pt(int(saved.slide_width)) > emu_to_pt(int(saved.slide_height))
    imaging = [slide for slide in saved.slides if slide_c_name(slide) == "Slide_Image1"]
    assert len(imaging) == 1
    assert (tmp_path / "chrome.png").is_file()

    set_page_title(project, "キズ検査")
    from smart_report_builder.project_store import save_project
    from smart_report_builder.layout import layout_slide as place

    save_project(project, tmp_path / "project.json")
    placed = place(project)
    write_pptx_slides([placed], tmp_path / "report.pptx", prior_path=tmp_path / "report.pptx")
    updated = Presentation(tmp_path / "report.pptx")
    slide = next(item for item in updated.slides if slide_c_name(item) == "Slide_Image1")
    assert _title_text(slide) == "キズ検査"
    assert len(updated.slides) == len(Presentation(bundled_template("landscape")).slides)


def _first_text(slide) -> str:
    for shape in slide.shapes:
        if shape.has_text_frame and shape.text_frame.text.strip():
            return shape.text_frame.text.strip().splitlines()[0]
    return ""


def _title_text(slide) -> str:
    for shape in slide.shapes:
        if shape.has_text_frame and shape.text_frame.text.strip() and not (shape.name or "").startswith(APP_SHAPE_PREFIX):
            return shape.text_frame.text.strip().splitlines()[0]
    return ""


def _prefixed_count(slide) -> int:
    return sum(1 for shape in slide.shapes if (shape.name or "").startswith(APP_SHAPE_PREFIX))


def _assert_on_page(presentation: Presentation) -> None:
    width = int(presentation.slide_width)
    for slide in presentation.slides:
        name = slide_c_name(slide) or ""
        if not name.startswith("Slide_Image"):
            continue
        for shape in slide.shapes:
            left = int(shape.left or 0)
            assert left < width
