"""LayoutResult だけを編集可能な PPTX にする。

画像は Picture、画像枠は矩形 Shape、説明文と注釈は TextBox、接続線は直線。
接続線の矢印は ROI 側を指す。線はコネクタのままなので、PowerPoint 上で編集できる。
配置の再計算はしない。元画像は読み取って埋め込み、ファイルは書き換えない。
"""

from __future__ import annotations

from pathlib import Path

from lxml import etree
from pptx import Presentation
from pptx.enum.shapes import MSO_CONNECTOR, MSO_SHAPE
from pptx.enum.text import MSO_AUTO_SIZE, PP_ALIGN
from pptx.dml.color import RGBColor
from pptx.oxml.ns import qn
from pptx.util import Emu, Pt

from smart_report_builder.imaging_template import (
    APP_SHAPE_PREFIX,
    DEFAULT_PAGE_TITLE,
    delete_slide,
    duplicate_slide,
    imaging_slide_indexes,
    move_slide,
    prepare_imaging_shell,
    replace_shape_text,
    set_slide_c_name,
)
from smart_report_builder.models import LayoutResult, PlacedElement, Rect
from smart_report_builder.units import pt_to_emu

_ROI_COLOR = RGBColor(0xFF, 0x00, 0x00)
_FONT_NAME = "Yu Gothic"
_FONT_SIZE_PT = 16


def write_pptx(result: LayoutResult, path: str | Path) -> None:
    write_pptx_slides([result], path)


def write_pptx_slides(
    results: list[LayoutResult],
    path: str | Path,
    *,
    prior_path: str | Path | None = None,
) -> None:
    if not results:
        raise ValueError("スライドがありません")
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    template = next((item.template_path for item in results if item.template_path), None)
    if template:
        _write_into_template(results, destination, Path(template), Path(prior_path) if prior_path else None)
        return

    presentation = Presentation()
    presentation.slide_width = Emu(pt_to_emu(results[0].slide_width_pt))
    presentation.slide_height = Emu(pt_to_emu(results[0].slide_height_pt))
    for result in results:
        _fill_slide(presentation.slides.add_slide(_blank_layout(presentation)), result)
    presentation.save(destination)


def _write_into_template(
    results: list[LayoutResult],
    destination: Path,
    template: Path,
    prior: Path | None,
) -> None:
    base = _template_base(template, prior)
    presentation = Presentation(str(base))
    _ensure_imaging_count(presentation, len(results))
    indexes = imaging_slide_indexes(presentation)
    if len(indexes) != len(results):
        raise ValueError("撮像スライドの枚数が揃わない")
    for number, (index, result) in enumerate(zip(indexes, results, strict=True), start=1):
        slide = presentation.slides[index]
        set_slide_c_name(slide, f"Slide_Image{number}")
        title = _title_shape(slide, result.title_shape_name)
        replace_shape_text(title, result.title_text or DEFAULT_PAGE_TITLE)
        _fill_slide(slide, result, prefix=APP_SHAPE_PREFIX, font_name=result.title_font)
    presentation.save(destination)


def _template_base(template: Path, prior: Path | None) -> Path:
    if prior is not None and prior.is_file() and _has_prototype(prior):
        return prior
    if template.is_file():
        return template
    raise ValueError("撮像スライドのテンプレートが見つからない")


def _has_prototype(path: Path) -> bool:
    try:
        presentation = Presentation(str(path))
    except Exception:
        return False
    return bool(imaging_slide_indexes(presentation))


def _ensure_imaging_count(presentation: Presentation, count: int) -> None:
    if count < 1:
        raise ValueError("スライドがありません")
    width = int(presentation.slide_width)
    height = int(presentation.slide_height)
    indexes = imaging_slide_indexes(presentation)
    if not indexes:
        raise ValueError("Slide_Image1 が見つからない")
    for index in indexes:
        prepare_imaging_shell(presentation.slides[index], width, height)
    indexes = imaging_slide_indexes(presentation)
    for index in reversed(indexes[count:]):
        delete_slide(presentation, index)
    while len(imaging_slide_indexes(presentation)) < count:
        indexes = imaging_slide_indexes(presentation)
        duplicate_slide(presentation, indexes[0])
        move_slide(presentation, len(presentation.slides) - 1, max(indexes) + 1)
        inserted = presentation.slides[max(indexes) + 1]
        set_slide_c_name(inserted, f"Slide_Image{len(indexes) + 1}")
        prepare_imaging_shell(inserted, width, height)


def _title_shape(slide, shape_name: str | None):
    if shape_name:
        for shape in slide.shapes:
            if shape.name == shape_name and shape.has_text_frame:
                return shape
    raise ValueError("タイトル図形が見つからない")


def _fill_slide(slide, result: LayoutResult, *, prefix: str = "", font_name: str | None = None) -> None:
    for element in result.elements:
        if element.kind == "image_frame" and element.asset_path and element.content_rect is not None:
            _add_picture(slide, element, prefix)
            if _heading_text(element):
                _add_frame_label(slide, element, prefix, font_name)
        elif element.kind == "text":
            _add_text(slide, element, prefix, font_name)
        elif element.kind == "table":
            _add_table(slide, element, prefix, font_name)
    for element in result.elements:
        if element.kind == "connector":
            _add_connector(slide, element, prefix)
    for element in result.elements:
        if element.kind == "roi":
            _add_roi(slide, element, prefix)
    for element in result.elements:
        if element.kind == "roi_label":
            _add_text(slide, element, prefix, font_name)


def _blank_layout(presentation: Presentation):
    """本文プレースホルダーのないレイアウト。日付・フッター・ページ番号だけは残ってよい。"""
    footer_indexes = {10, 11, 12}
    candidates = []
    for layout in presentation.slide_layouts:
        content_placeholders = [
            placeholder
            for placeholder in layout.placeholders
            if placeholder.placeholder_format.idx not in footer_indexes
        ]
        if not content_placeholders:
            candidates.append(layout)
    if not candidates:
        raise RuntimeError("テンプレートに空白のスライドレイアウトがない")
    for layout in candidates:
        if layout.name.lower() == "blank":
            return layout
    return candidates[0]


def _add_picture(slide, element: PlacedElement, prefix: str) -> None:
    content = element.content_rect
    if content is None or element.asset_path is None or not _positive(content):
        return
    picture = slide.shapes.add_picture(element.asset_path, *_emu_box(content))
    picture.name = _shape_name(prefix, f"{element.display_name}（画像）")
    if element.crop is not None:
        picture.crop_left = element.crop.x
        picture.crop_top = element.crop.y
        picture.crop_right = 1 - element.crop.x - element.crop.width
        picture.crop_bottom = 1 - element.crop.y - element.crop.height


def _add_roi(slide, element: PlacedElement, prefix: str) -> None:
    if not _positive(element.frame):
        return
    shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, *_emu_box(element.frame))
    shape.name = _shape_name(prefix, element.display_name)
    shape.fill.background()
    shape.line.color.rgb = _ROI_COLOR
    shape.line.width = Pt(1.5)
    _without_theme_effects(shape)


def _add_connector(slide, element: PlacedElement, prefix: str) -> None:
    start = element.line_start
    end = element.line_end
    if start is None or end is None:
        return
    shape = slide.shapes.add_connector(
        MSO_CONNECTOR.STRAIGHT,
        Emu(pt_to_emu(start.x)),
        Emu(pt_to_emu(start.y)),
        Emu(pt_to_emu(end.x)),
        Emu(pt_to_emu(end.y)),
    )
    shape.name = _shape_name(prefix, element.display_name)
    shape.line.color.rgb = _ROI_COLOR
    shape.line.width = Pt(1.5)
    _without_theme_effects(shape)
    _arrow_toward_roi(shape)


def _without_theme_effects(shape) -> None:
    """テーマの効果参照を外し、影のない線だけの図形にする。"""
    element = shape._element
    style = element.find(qn("p:style"))
    if style is not None:
        element.remove(style)
    sp_pr = element.spPr
    if sp_pr.find(qn("a:effectLst")) is None:
        etree.SubElement(sp_pr, qn("a:effectLst"))


def _arrow_toward_roi(shape) -> None:
    """始点（ROI 側）に三角の矢印を付ける。終点側には付けない。"""
    line = shape.line._get_or_add_ln()
    if line.find(qn("a:headEnd")) is not None:
        return
    head = etree.SubElement(line, qn("a:headEnd"))
    head.set("type", "triangle")
    head.set("w", "med")
    head.set("len", "med")


def _add_table(slide, element: PlacedElement, prefix: str, font_name: str | None) -> None:
    rows = element.table_rows or []
    if not rows or not rows[0] or not _positive(element.frame):
        return
    columns = max(len(row) for row in rows)
    shape = slide.shapes.add_table(
        len(rows),
        columns,
        *_emu_box(element.frame),
    )
    shape.name = _shape_name(prefix, element.display_name)
    for row_index, row in enumerate(rows):
        for column_index in range(columns):
            value = row[column_index] if column_index < len(row) else ""
            cell = shape.table.cell(row_index, column_index)
            cell.text = value
            for paragraph in cell.text_frame.paragraphs:
                for run in paragraph.runs:
                    _apply_font(run, font_name or _FONT_NAME, _FONT_SIZE_PT)


def _heading_text(element) -> str:
    if element.rendered_text is not None:
        return element.rendered_text
    return element.text or ""


def _add_frame_label(slide, element: PlacedElement, prefix: str, font_name: str | None) -> None:
    box = element.label_frame
    if box is None or not _positive(box):
        return
    shape = slide.shapes.add_textbox(*_emu_box(box))
    shape.name = _shape_name(prefix, f"{element.display_name}（ラベル）")
    shape.text_frame.word_wrap = True
    shape.text_frame.text = _heading_text(element)
    size = element.font_pt or 14.0
    for paragraph in shape.text_frame.paragraphs:
        if element.text_anchor == "below":
            paragraph.alignment = PP_ALIGN.CENTER
        for run in paragraph.runs:
            _apply_font(run, font_name or _FONT_NAME, size)


def _add_text(slide, element: PlacedElement, prefix: str, font_name: str | None) -> None:
    if not _positive(element.frame):
        return
    box = slide.shapes.add_textbox(*_emu_box(element.frame))
    box.name = _shape_name(prefix, element.display_name)
    text_frame = box.text_frame
    text_frame.clear()
    text_frame.word_wrap = True
    text_frame.auto_size = MSO_AUTO_SIZE.NONE
    text_frame.margin_left = Emu(0)
    text_frame.margin_right = Emu(0)
    text_frame.margin_top = Emu(0)
    text_frame.margin_bottom = Emu(0)
    text_frame.text = element.text or ""
    size = element.font_pt or _FONT_SIZE_PT
    for paragraph in text_frame.paragraphs:
        for run in paragraph.runs:
            _apply_font(run, font_name or _FONT_NAME, size)


def _shape_name(prefix: str, name: str) -> str:
    return f"{prefix}{name}" if prefix else name


def _apply_font(run, name: str, size_pt: float) -> None:
    run.font.size = Pt(size_pt)
    run.font.name = name
    properties = run._r.get_or_add_rPr()
    for tag in ("a:latin", "a:ea", "a:cs"):
        node = properties.find(qn(tag))
        if node is None:
            node = etree.SubElement(properties, qn(tag))
        node.set("typeface", name)


def _positive(rect: Rect) -> bool:
    return pt_to_emu(rect.width) > 0 and pt_to_emu(rect.height) > 0


def _emu_box(rect: Rect) -> tuple[Emu, Emu, Emu, Emu]:
    return (
        Emu(pt_to_emu(rect.x)),
        Emu(pt_to_emu(rect.y)),
        Emu(pt_to_emu(rect.width)),
        Emu(pt_to_emu(rect.height)),
    )
