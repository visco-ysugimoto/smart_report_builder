"""評価レポートの縦横テンプレートから、撮像画像スライドの本文領域を読む。

ヘッダー、ロゴ、フッターはレイアウト側の静画にする。本文プレースホルダーの中だけを
アプリの配置領域にする。テンプレート本体は変更しない。
"""

from __future__ import annotations

import os
import shutil
from copy import deepcopy
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

from lxml import etree
from PIL import Image, ImageDraw, ImageFont
from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE, PP_PLACEHOLDER
from pptx.opc.constants import RELATIONSHIP_TYPE as RT
from pptx.oxml.ns import qn

from smart_report_builder.models import Rect
from smart_report_builder.units import emu_to_pt

LAYOUT_NAME = "2_ViSCO_評価"
PROTOTYPE_NAME = "Slide_Image1"
APP_SHAPE_PREFIX = "SRB_"
DEFAULT_PAGE_TITLE = "撮像画像"
CHROME_DPI = 96

_SCHEME_ALIAS = {"tx1": "dk1", "bg1": "lt1", "tx2": "dk2", "bg2": "lt2"}
_A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
_R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


@dataclass(frozen=True)
class ChromeShape:
    kind: str
    rect: Rect
    fill: tuple[int, int, int, int] | None = None
    text: str = ""
    font_name: str | None = None
    font_pt: float | None = None
    font_color: tuple[int, int, int, int] | None = None
    image_blob: bytes | None = None


@dataclass(frozen=True)
class ImagingTemplate:
    slide_width_pt: float
    slide_height_pt: float
    body: Rect
    title_frame: Rect
    title_shape_name: str
    title_font: str
    title_font_pt: float
    title_color: str
    chrome: tuple[ChromeShape, ...]


def bundled_template(orientation: str) -> Path:
    if orientation == "portrait":
        name = "jp_portrait.pptx"
    elif orientation == "landscape":
        name = "jp_landscape.pptx"
    else:
        raise ValueError("用紙は縦か横です")
    path = Path(__file__).resolve().parent / "templates" / name
    if not path.is_file():
        raise ValueError("撮像スライドのテンプレートが見つからない")
    return path


def read_imaging_template(path: str | Path) -> ImagingTemplate:
    presentation = Presentation(str(path))
    slide = _prototype_slide(presentation)
    layout = slide.slide_layout
    if layout.name != LAYOUT_NAME:
        raise ValueError(f"撮像スライドのレイアウトが {LAYOUT_NAME} ではない")
    body = _body_rect(layout)
    title = _title_shape(slide)
    font_name, font_pt, font_color = _text_style(title, _theme_colors(layout.slide_master))
    theme = _theme_colors(layout.slide_master)
    chrome = tuple(
        shape
        for shape in (_chrome_shape(item, theme, body) for item in layout.shapes)
        if shape is not None
    )
    width = emu_to_pt(int(presentation.slide_width))
    height = emu_to_pt(int(presentation.slide_height))
    return ImagingTemplate(
        slide_width_pt=width,
        slide_height_pt=height,
        body=body,
        title_frame=_rect_pt(title),
        title_shape_name=title.name,
        title_font=font_name,
        title_font_pt=font_pt,
        title_color=_hex_color(font_color),
        chrome=chrome,
    )


def materialize_template(project, directory: str | Path) -> None:
    """選んだテンプレートをプロジェクトへコピーし、プレビュー用の静画を作る。"""
    design = project.design_master
    if design.orientation not in {"portrait", "landscape"}:
        return
    folder = Path(directory)
    folder.mkdir(parents=True, exist_ok=True)
    source = bundled_template(design.orientation)
    destination = folder / "template.pptx"
    if not destination.exists():
        shutil.copyfile(source, destination)
    design.template_path = str(destination.resolve())
    chrome = folder / "chrome.png"
    if not chrome.exists():
        render_chrome(read_imaging_template(destination), chrome)
    design.chrome_image = str(chrome.resolve())


def render_chrome(spec: ImagingTemplate, destination: str | Path) -> None:
    """ヘッダーとフッターを、プレビュー用の静画にする。タイトル文字は描かない。"""
    width = max(1, round(spec.slide_width_pt * CHROME_DPI / 72))
    height = max(1, round(spec.slide_height_pt * CHROME_DPI / 72))
    canvas = Image.new("RGBA", (width, height), (255, 255, 255, 255))
    for shape in spec.chrome:
        _paint_shape(canvas, shape)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, format="PNG")


def slide_c_name(slide) -> str | None:
    element = slide._element.find(qn("p:cSld"))
    if element is None:
        return None
    name = element.get("name")
    return name or None


def set_slide_c_name(slide, name: str) -> None:
    element = slide._element.find(qn("p:cSld"))
    if element is None:
        raise ValueError("スライド名を書けない")
    element.set("name", name)


def imaging_slide_names_at(path: str | Path) -> list[str]:
    return imaging_slide_names(Presentation(str(path)))


def imaging_slide_names(presentation: Presentation) -> list[str]:
    names: list[str] = []
    for slide in presentation.slides:
        name = slide_c_name(slide) or ""
        if name.startswith("Slide_Image"):
            names.append(name)
    return names


def imaging_slide_indexes(presentation: Presentation) -> list[int]:
    found: list[int] = []
    for index, slide in enumerate(presentation.slides):
        name = slide_c_name(slide) or ""
        if name.startswith("Slide_Image"):
            found.append(index)
    return found


def prepare_imaging_shell(slide, slide_width_emu: int, slide_height_emu: int) -> None:
    """アプリが描いた図形と、ページの外に置かれた見本を外す。タイトルは残す。"""
    for shape in list(slide.shapes):
        name = shape.name or ""
        if name.startswith(APP_SHAPE_PREFIX) or not _on_slide(shape, slide_width_emu, slide_height_emu):
            _remove_shape(shape)


def duplicate_slide(presentation: Presentation, index: int):
    """同じレイアウトのスライドを複製する。ページ外の図形はコピーしない。"""
    source = presentation.slides[index]
    dest = presentation.slides.add_slide(source.slide_layout)
    for shape in list(dest.shapes):
        _remove_shape(shape)
    mapping: dict[str, str] = {}
    for rel in source.part.rels.values():
        if rel.reltype in {RT.SLIDE_LAYOUT, RT.NOTES_SLIDE}:
            continue
        if rel.is_external:
            mapping[rel.rId] = dest.part.rels.get_or_add_ext_rel(rel.reltype, rel.target_ref)
        else:
            mapping[rel.rId] = dest.part.relate_to(rel.target_part, rel.reltype)
    for shape in source.shapes:
        if not _on_slide(shape, int(presentation.slide_width), int(presentation.slide_height)):
            continue
        cloned = deepcopy(shape._element)
        _remap_rids(cloned, mapping)
        dest.shapes._spTree.append(cloned)
    return dest


def move_slide(presentation: Presentation, old_index: int, new_index: int) -> None:
    if old_index == new_index:
        return
    listing = presentation.slides._sldIdLst
    element = list(listing)[old_index]
    listing.remove(element)
    listing.insert(new_index, element)


def delete_slide(presentation: Presentation, index: int) -> None:
    listing = presentation.slides._sldIdLst
    element = list(listing)[index]
    relation_id = element.get(qn("r:id"))
    presentation.part.drop_rel(relation_id)
    listing.remove(element)


def replace_shape_text(shape, text: str) -> None:
    """先頭の文字だけ差し替える。書式は残す。"""
    frame = shape.text_frame
    paragraph = frame.paragraphs[0]
    runs = list(paragraph.runs)
    if runs:
        runs[0].text = text
        for run in runs[1:]:
            run.text = ""
    else:
        paragraph.text = text
    body = frame._txBody
    paragraphs = body.findall(qn("a:p"))
    for extra in paragraphs[1:]:
        for node in extra.findall(qn("a:r")):
            node_text = node.find(qn("a:t"))
            if node_text is not None:
                node_text.text = ""


def _prototype_slide(presentation: Presentation):
    for slide in presentation.slides:
        if slide_c_name(slide) == PROTOTYPE_NAME:
            return slide
    raise ValueError("Slide_Image1 が見つからない")


def _body_rect(layout) -> Rect:
    for shape in layout.placeholders:
        if shape.placeholder_format.type == PP_PLACEHOLDER.OBJECT:
            rect = _rect_pt(shape)
            if rect.width > 1 and rect.height > 1:
                return rect
    raise ValueError("本文のプレースホルダーがない")


def _title_shape(slide):
    for shape in slide.shapes:
        if shape.has_text_frame and DEFAULT_PAGE_TITLE in shape.text_frame.text:
            return shape
    for shape in slide.shapes:
        if getattr(shape, "is_placeholder", False) and shape.placeholder_format.type == PP_PLACEHOLDER.TITLE:
            return shape
    raise ValueError("撮像画像のタイトルが見つからない")


def _rect_pt(shape) -> Rect:
    return Rect(
        x=emu_to_pt(int(shape.left or 0)),
        y=emu_to_pt(int(shape.top or 0)),
        width=emu_to_pt(int(shape.width or 0)),
        height=emu_to_pt(int(shape.height or 0)),
    )


def _theme_colors(master) -> dict[str, tuple[int, int, int]]:
    theme_part = None
    for rel in master.part.rels.values():
        if rel.reltype == RT.THEME:
            theme_part = rel.target_part
            break
    if theme_part is None:
        return {}
    root = etree.fromstring(theme_part.blob)
    scheme = root.find(f".//{{{_A_NS}}}clrScheme")
    colors: dict[str, tuple[int, int, int]] = {}
    if scheme is None:
        return colors
    for child in scheme:
        name = etree.QName(child).localname
        srgb = child.find(f".//{{{_A_NS}}}srgbClr")
        system = child.find(f".//{{{_A_NS}}}sysClr")
        raw = None
        if srgb is not None and srgb.get("val"):
            raw = srgb.get("val")
        elif system is not None and system.get("lastClr"):
            raw = system.get("lastClr")
        parsed = _parse_hex(raw)
        if parsed is not None:
            colors[name] = parsed
    return colors


def _chrome_shape(shape, theme: dict[str, tuple[int, int, int]], body: Rect) -> ChromeShape | None:
    if _is_placeholder(shape):
        return None
    if shape.shape_type not in {MSO_SHAPE_TYPE.AUTO_SHAPE, MSO_SHAPE_TYPE.TEXT_BOX, MSO_SHAPE_TYPE.PICTURE}:
        return None
    rect = _rect_pt(shape)
    if rect.width <= 1 or rect.height <= 1:
        return None
    if not _center_outside(rect, body):
        return None
    if shape.shape_type == MSO_SHAPE_TYPE.PICTURE:
        try:
            blob = shape.image.blob
        except Exception:
            return None
        return ChromeShape(kind="picture", rect=rect, image_blob=blob)
    fill = _solid_rgba(shape._element.find(qn("p:spPr")), theme)
    text = ""
    font_name = None
    font_pt = None
    font_color = None
    if shape.has_text_frame:
        lines = [paragraph.text for paragraph in shape.text_frame.paragraphs if paragraph.text]
        text = "\n".join(lines)
        font_name, font_pt, font_color = _text_style(shape, theme)
    if fill is None and not text:
        return None
    return ChromeShape(
        kind="text" if text else "rect",
        rect=rect,
        fill=fill,
        text=text,
        font_name=font_name,
        font_pt=font_pt,
        font_color=font_color,
    )


def _is_placeholder(shape) -> bool:
    try:
        return bool(shape.is_placeholder)
    except Exception:
        return False


def _center_outside(rect: Rect, body: Rect) -> bool:
    center_x = rect.x + rect.width / 2
    center_y = rect.y + rect.height / 2
    inside = body.x <= center_x <= body.x + body.width and body.y <= center_y <= body.y + body.height
    return not inside


def _text_style(shape, theme: dict[str, tuple[int, int, int]]) -> tuple[str, float, tuple[int, int, int, int]]:
    font_name = "Yu Gothic Medium"
    font_pt = 18.0
    color = (26, 26, 26, 255)
    if not shape.has_text_frame:
        return font_name, font_pt, color
    for paragraph in shape.text_frame.paragraphs:
        for run in paragraph.runs:
            r_pr = run._r.find(qn("a:rPr"))
            found_name = _typeface(r_pr)
            found_pt = _font_pt(r_pr)
            found_color = _solid_rgba(r_pr, theme) if r_pr is not None else None
            if found_name:
                font_name = found_name
            if found_pt:
                font_pt = found_pt
            if found_color is not None:
                color = found_color
            if paragraph.text:
                return font_name, font_pt, color
    return font_name, font_pt, color


def _typeface(r_pr) -> str | None:
    if r_pr is None:
        return None
    for tag in ("a:ea", "a:latin", "a:cs"):
        node = r_pr.find(qn(tag))
        if node is None:
            continue
        face = node.get("typeface")
        if face and not face.startswith("+"):
            return face
    return None


def _font_pt(r_pr) -> float | None:
    if r_pr is None or not r_pr.get("sz"):
        return None
    return int(r_pr.get("sz")) / 100


def _solid_rgba(element, theme: dict[str, tuple[int, int, int]]) -> tuple[int, int, int, int] | None:
    if element is None:
        return None
    solid = element.find(qn("a:solidFill"))
    if solid is None:
        return None
    srgb = solid.find(qn("a:srgbClr"))
    scheme = solid.find(qn("a:schemeClr"))
    node = srgb if srgb is not None else scheme
    if node is None:
        return None
    alpha = 255
    alpha_node = node.find(qn("a:alpha"))
    if alpha_node is not None and alpha_node.get("val"):
        alpha = round(int(alpha_node.get("val")) * 255 / 100000)
        alpha = min(255, max(0, alpha))
    if srgb is not None:
        rgb = _parse_hex(srgb.get("val"))
    else:
        name = scheme.get("val") if scheme is not None else None
        rgb = theme.get(_SCHEME_ALIAS.get(name or "", name or ""))
    if rgb is None:
        return None
    return (*rgb, alpha)


def _parse_hex(raw: str | None) -> tuple[int, int, int] | None:
    if not raw or len(raw) != 6:
        return None
    try:
        return tuple(int(raw[index : index + 2], 16) for index in (0, 2, 4))  # type: ignore[return-value]
    except ValueError:
        return None


def _hex_color(color: tuple[int, int, int, int]) -> str:
    return f"#{color[0]:02X}{color[1]:02X}{color[2]:02X}"


def _paint_shape(canvas: Image.Image, shape: ChromeShape) -> None:
    box = _pixel_box(canvas.size, shape.rect)
    if box is None:
        return
    left, top, right, bottom = box
    if shape.kind == "picture" and shape.image_blob:
        _paste_picture(canvas, shape.image_blob, left, top, right - left, bottom - top)
        return
    if shape.fill is not None:
        overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        ImageDraw.Draw(overlay).rectangle([left, top, right, bottom], fill=shape.fill)
        canvas.alpha_composite(overlay)
    if shape.text:
        _paint_text(canvas, shape, left, top)


def _pixel_box(size: tuple[int, int], rect: Rect) -> tuple[int, int, int, int] | None:
    width, height = size
    left = round(rect.x * CHROME_DPI / 72)
    top = round(rect.y * CHROME_DPI / 72)
    right = round((rect.x + rect.width) * CHROME_DPI / 72)
    bottom = round((rect.y + rect.height) * CHROME_DPI / 72)
    left = min(max(left, 0), width)
    top = min(max(top, 0), height)
    right = min(max(right, 0), width)
    bottom = min(max(bottom, 0), height)
    if right <= left or bottom <= top:
        return None
    return left, top, right, bottom


def _paste_picture(canvas: Image.Image, blob: bytes, left: int, top: int, width: int, height: int) -> None:
    try:
        image = Image.open(BytesIO(blob)).convert("RGBA")
    except Exception:
        return
    image = image.resize((max(1, width), max(1, height)), Image.Resampling.LANCZOS)
    canvas.alpha_composite(image, (left, top))


def _paint_text(canvas: Image.Image, shape: ChromeShape, left: int, top: int) -> None:
    size = max(1, round((shape.font_pt or 12) * CHROME_DPI / 72))
    path = _font_file(shape.font_name or "")
    if path is None:
        return
    try:
        font = ImageFont.truetype(path, size=size)
    except Exception:
        return
    ImageDraw.Draw(canvas).multiline_text((left, top), shape.text, font=font, fill=shape.font_color or (0, 0, 0, 255))


def _font_file(typeface: str) -> str | None:
    windows = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts"
    preferred = {
        "yu gothic medium": ("YuGothM.ttc", "YuGothR.ttc"),
        "yu gothic": ("YuGothR.ttc", "YuGothM.ttc"),
        "meiryo ui": ("meiryo.ttc", "YuGothM.ttc"),
        "meiryo": ("meiryo.ttc",),
    }
    names = list(preferred.get(typeface.lower(), ())) + ["YuGothM.ttc", "meiryo.ttc", "msgothic.ttc"]
    for name in names:
        path = windows / name
        if path.is_file():
            return str(path)
    return None


def _on_slide(shape, slide_width_emu: int, slide_height_emu: int) -> bool:
    left = int(shape.left or 0)
    top = int(shape.top or 0)
    right = left + int(shape.width or 0)
    bottom = top + int(shape.height or 0)
    if right <= left or bottom <= top:
        return True
    return right > 0 and bottom > 0 and left < slide_width_emu and top < slide_height_emu


def _remove_shape(shape) -> None:
    element = shape._element
    parent = element.getparent()
    if parent is not None:
        parent.remove(element)


def _remap_rids(element, mapping: dict[str, str]) -> None:
    for node in element.iter():
        for attribute in ("embed", "link"):
            key = f"{{{_R_NS}}}{attribute}"
            value = node.get(key)
            if value in mapping:
                node.set(key, mapping[value])
