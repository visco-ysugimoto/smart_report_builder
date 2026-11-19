"""プロジェクトのインメモリモデル。

DesignMaster、ContentMaster、Asset、Binding、SlideInstance は別の型として持つ。
ファイルへの読み書きは project_store が担当し、このモジュールは dict への変換だけを行う。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Literal, Union
import uuid


SCHEMA_VERSION = 2
READABLE_SCHEMA_VERSIONS = {1, 2}
LAYOUT_SCHEMA_VERSION = 1

SLIDE_WIDTH_PT = 960.0
SLIDE_HEIGHT_PT = 540.0
MARGIN_PT = 36.0
GAP_PT = 12.0
TEXT_HEIGHT_PT = 96.0


def new_id() -> str:
    return uuid.uuid4().hex


class FitMode(str, Enum):
    CONTAIN = "contain"
    COVER = "cover"
    ROI = "roi"


class CoordSpace(str, Enum):
    NORMALIZED = "normalized"
    PIXEL = "pixel"


class Inheritance(str, Enum):
    INHERIT = "inherit"
    RELATIVE = "relative_override"
    DETACHED = "detached"


class StackDirection(str, Enum):
    HORIZONTAL = "horizontal"
    VERTICAL = "vertical"


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    width: float
    height: float

    def to_dict(self) -> dict[str, float]:
        return {
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> Rect:
        return Rect(
            x=float(_required(data, "x")),
            y=float(_required(data, "y")),
            width=float(_required(data, "width")),
            height=float(_required(data, "height")),
        )


@dataclass
class ImageFrameNode:
    id: str
    role_id: str
    display_name: str
    fit_mode: FitMode = FitMode.CONTAIN
    # 親の並びの中での位置と大きさ。未指定のときは等分のまま。
    free_rect: Rect | None = None
    kind: Literal["image_frame"] = "image_frame"


@dataclass
class TextNode:
    id: str
    role_id: str
    display_name: str
    text: str
    height_pt: float = TEXT_HEIGHT_PT
    kind: Literal["text"] = "text"


@dataclass
class TableNode:
    id: str
    display_name: str
    headers: list[str]
    rows: list[list[str]]
    height_pt: float = 72.0
    kind: Literal["table"] = "table"


@dataclass
class StackNode:
    id: str
    direction: StackDirection
    children: list[Element]
    gap_pt: float = GAP_PT
    # 画像の縦横比で子の配分を変える。未指定の既存プロジェクトは等分のまま。
    track_aspect: bool = False
    emphasize_first: bool = False
    kind: Literal["stack"] = "stack"


@dataclass
class GridNode:
    id: str
    columns: int
    children: list[Element]
    gap_pt: float = GAP_PT
    kind: Literal["grid"] = "grid"


Element = Union[StackNode, GridNode, ImageFrameNode, TextNode, TableNode]


@dataclass
class DesignMaster:
    id: str
    slide_width_pt: float = SLIDE_WIDTH_PT
    slide_height_pt: float = SLIDE_HEIGHT_PT
    margin_pt: float = MARGIN_PT
    schema_version: int = SCHEMA_VERSION
    template_path: str | None = None
    orientation: str | None = None
    body: Rect | None = None
    title_frame: Rect | None = None
    title_shape_name: str | None = None
    title_font: str | None = None
    title_font_pt: float | None = None
    title_color: str | None = None
    page_title: str = "撮像画像"
    chrome_image: str | None = None


@dataclass
class FrameMapping:
    """古いルールの枠と番号。読み込み時に FrameRef へ移す。"""

    element_id: str
    item_number: int


@dataclass
class FrameRef:
    """1つの画像枠が参照するリストと番号。番号は1始まり。"""

    element_id: str
    frame_index: int
    list_by: str
    list_key: str
    item_number: int
    label_template: str = ""


@dataclass
class TextTemplate:
    """文章枠へ入れる差し込み文字列。"""

    element_id: str
    template: str


@dataclass
class SlideOverride:
    """繰り返しを使わない、そのスライドだけの参照。"""

    slide_ordinal: int
    frames: list[FrameRef] = field(default_factory=list)


@dataclass
class AssignmentRule:
    """マスターに保存する割付ルール。候補を出すだけで、割当は書かない。

    pattern が1枚分の枠参照。step を足しながら次のスライドへ広げる。
    overrides はその番号のスライドだけを置き換える。
    """

    mode: str = "pattern"
    offset: int = 1
    stride: int = 1
    per_slide: int = 2
    mappings: list[FrameMapping] = field(default_factory=list)
    step: int = 1
    pattern: list[FrameRef] = field(default_factory=list)
    overrides: list[SlideOverride] = field(default_factory=list)
    # 1始まり。range_to が空なら、リストが尽きるまで広げる。
    range_from: int = 1
    range_to: int | None = None
    title_template: str = ""
    text_templates: list[TextTemplate] = field(default_factory=list)


@dataclass
class ContentMaster:
    id: str
    design_master_id: str
    name: str
    root: Element
    schema_version: int = SCHEMA_VERSION
    master_rois: list[MasterRoi] = field(default_factory=list)
    assignment_rule: AssignmentRule | None = None


@dataclass
class Asset:
    id: str
    path: str
    width_px: int
    height_px: int
    display_name: str
    kind: Literal["image"] = "image"
    source: str | None = None
    group: str | None = None
    task: str | None = None
    list_name: str | None = None
    list_comment: str | None = None
    list_index: int | None = None
    file_name: str | None = None
    note: str = ""


@dataclass
class Binding:
    element_id: str
    asset_id: str | None = None
    text: str | None = None


@dataclass
class Roi:
    """スライドに置いた矩形 ROI。

    座標は元画像に対する正規化座標（0〜1）か、元画像のピクセル座標。
    マスターへ継承しているときは、配置の座標はマスターと差分から求める。
    """

    id: str
    name: str
    source_element_id: str
    x: float
    y: float
    width: float
    height: float
    zoom_element_id: str | None = None
    coord_space: CoordSpace = CoordSpace.NORMALIZED
    note: str = ""
    note_dx: float | None = None
    note_dy: float | None = None
    master_roi_id: str | None = None
    inheritance: Inheritance = Inheritance.DETACHED
    dx: float = 0.0
    dy: float = 0.0
    dw: float = 0.0
    dh: float = 0.0


@dataclass
class MasterRoi:
    """マスター上の標準 ROI。個別の補正は Roi 側に残す。"""

    id: str
    name: str
    source_element_id: str
    x: float
    y: float
    width: float
    height: float
    coord_space: CoordSpace = CoordSpace.NORMALIZED
    note: str = ""


@dataclass
class Dataset:
    """フォルダに依存しない素材のグループ。枠への割当は持たない。"""

    id: str
    name: str
    asset_ids: list[str] = field(default_factory=list)


@dataclass
class SlideInstance:
    id: str
    content_master_id: str
    bindings: list[Binding] = field(default_factory=list)
    rois: list[Roi] = field(default_factory=list)
    title: str = ""


@dataclass
class LayoutDefinition:
    """複数のスライドから参照できる配置。枠の並びを持ち、画像の割当は持たない。"""

    id: str
    name: str
    content_master: ContentMaster


@dataclass
class ReportSlide:
    """報告の1枚。使うレイアウトと、その枚だけの画像・ROI・タイトルを持つ。"""

    id: str
    name: str
    layout_id: str
    slide: SlideInstance


@dataclass
class Project:
    design_master: DesignMaster
    content_master: ContentMaster
    assets: list[Asset]
    slide: SlideInstance
    datasets: list[Dataset] = field(default_factory=list)
    layouts: list[LayoutDefinition] = field(default_factory=list)
    report_slides: list[ReportSlide] = field(default_factory=list)
    active_slide_id: str | None = None
    schema_version: int = SCHEMA_VERSION


@dataclass(frozen=True)
class Point:
    x: float
    y: float

    def to_dict(self) -> dict[str, float]:
        return {"x": self.x, "y": self.y}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Point:
        return cls(x=float(_required(data, "x")), y=float(_required(data, "y")))


@dataclass(frozen=True)
class LayoutViolation:
    code: str
    element_id: str
    message: str


@dataclass(frozen=True)
class PlacedElement:
    element_id: str
    kind: Literal["image_frame", "text", "roi", "roi_label", "connector", "table"]
    role_id: str
    display_name: str
    frame: Rect
    content_rect: Rect | None = None
    text: str | None = None
    asset_path: str | None = None
    fit_mode: str = FitMode.CONTAIN.value
    crop: Rect | None = None
    source_element_id: str | None = None
    line_start: Point | None = None
    line_end: Point | None = None
    table_rows: list[list[str]] | None = None
    group_frame: Rect | None = None


@dataclass(frozen=True)
class LayoutResult:
    slide_width_pt: float
    slide_height_pt: float
    elements: list[PlacedElement]
    violations: list[LayoutViolation]
    schema_version: int = LAYOUT_SCHEMA_VERSION
    preview_mode: str = "provisional"
    template_path: str | None = None
    chrome_image: str | None = None
    title_text: str | None = None
    title_frame: Rect | None = None
    title_font: str | None = None
    title_font_pt: float | None = None
    title_color: str | None = None
    title_shape_name: str | None = None


def project_to_dict(project: Project) -> dict[str, Any]:
    payload = {
        "schemaVersion": project.schema_version,
        "designMaster": _design_to_dict(project.design_master),
        "contentMaster": _content_to_dict(project.content_master),
        "assets": [_asset_to_dict(asset) for asset in project.assets],
        "slide": _slide_to_dict(project.slide),
    }
    if project.datasets:
        payload["datasets"] = [_dataset_to_dict(item) for item in project.datasets]
    if len(project.report_slides) > 1 or len(project.layouts) > 1:
        payload["layouts"] = [_layout_to_dict(item) for item in project.layouts]
        payload["slides"] = [_report_slide_to_dict(item) for item in project.report_slides]
        payload["activeSlideId"] = project.active_slide_id
    return payload


def layout_result_to_dict(result: LayoutResult) -> dict[str, Any]:
    payload = {
        "schemaVersion": result.schema_version,
        "slideWidthPt": result.slide_width_pt,
        "slideHeightPt": result.slide_height_pt,
        "elements": [_placed_to_dict(element) for element in result.elements],
        "previewMode": result.preview_mode,
        "violations": [
            {
                "code": violation.code,
                "elementId": violation.element_id,
                "message": violation.message,
            }
            for violation in result.violations
        ],
    }
    _put_optional(payload, "templatePath", result.template_path)
    _put_optional(payload, "chromeImage", result.chrome_image)
    _put_optional(payload, "titleText", result.title_text)
    if result.title_frame is not None:
        payload["titleFrame"] = result.title_frame.to_dict()
    _put_optional(payload, "titleFont", result.title_font)
    if result.title_font_pt is not None:
        payload["titleFontPt"] = result.title_font_pt
    _put_optional(payload, "titleColor", result.title_color)
    _put_optional(payload, "titleShapeName", result.title_shape_name)
    return payload


def layout_result_from_dict(data: dict[str, Any]) -> LayoutResult:
    version = _required(data, "schemaVersion")
    if version != LAYOUT_SCHEMA_VERSION:
        raise ValueError(f"unsupported schemaVersion: {version}")
    elements = [_placed_from_dict(item) for item in _required(data, "elements")]
    stored_mode = data.get("previewMode")
    if stored_mode not in {"provisional", "real", "partial"}:
        stored_mode = preview_mode_of(elements)
    title_frame = data.get("titleFrame")
    return LayoutResult(
        schema_version=int(version),
        slide_width_pt=float(_required(data, "slideWidthPt")),
        slide_height_pt=float(_required(data, "slideHeightPt")),
        elements=elements,
        violations=[
            LayoutViolation(
                code=str(_required(item, "code")),
                element_id=str(_required(item, "elementId")),
                message=str(_required(item, "message")),
            )
            for item in _required(data, "violations")
        ],
        preview_mode=str(stored_mode),
        template_path=_optional_str(data, "templatePath"),
        chrome_image=_optional_str(data, "chromeImage"),
        title_text=_optional_str(data, "titleText"),
        title_frame=Rect.from_dict(title_frame) if isinstance(title_frame, dict) else None,
        title_font=_optional_str(data, "titleFont"),
        title_font_pt=None if data.get("titleFontPt") is None else float(data["titleFontPt"]),
        title_color=_optional_str(data, "titleColor"),
        title_shape_name=_optional_str(data, "titleShapeName"),
    )


def preview_mode_of(elements: list[PlacedElement]) -> str:
    """通常表示の画像枠だけを見る。拡大枠は仮か実かの判定に入れない。"""
    contain = [
        element
        for element in elements
        if element.kind == "image_frame" and element.fit_mode == FitMode.CONTAIN.value
    ]
    filled = [element for element in contain if element.content_rect is not None]
    if not contain or not filled:
        return "provisional"
    if len(filled) == len(contain):
        return "real"
    return "partial"


def _placed_to_dict(element: PlacedElement) -> dict[str, Any]:
    payload = {
        "elementId": element.element_id,
        "kind": element.kind,
        "roleId": element.role_id,
        "displayName": element.display_name,
        "frame": element.frame.to_dict(),
        "contentRect": None if element.content_rect is None else element.content_rect.to_dict(),
        "text": element.text,
        "assetPath": element.asset_path,
        "fitMode": element.fit_mode,
        "crop": None if element.crop is None else element.crop.to_dict(),
        "sourceElementId": element.source_element_id,
        "lineStart": None if element.line_start is None else element.line_start.to_dict(),
        "lineEnd": None if element.line_end is None else element.line_end.to_dict(),
    }
    if element.table_rows is not None:
        payload["tableRows"] = element.table_rows
    if element.group_frame is not None:
        payload["groupFrame"] = element.group_frame.to_dict()
    return payload


def _placed_from_dict(data: dict[str, Any]) -> PlacedElement:
    kind = str(_required(data, "kind"))
    if kind not in ("image_frame", "text", "roi", "roi_label", "connector", "table"):
        raise ValueError(f"unknown placed element kind: {kind}")
    content = data.get("contentRect")
    crop = data.get("crop")
    return PlacedElement(
        element_id=str(_required(data, "elementId")),
        kind=kind,
        role_id=str(_required(data, "roleId")),
        display_name=str(_required(data, "displayName")),
        frame=Rect.from_dict(_required(data, "frame")),
        content_rect=None if content is None else Rect.from_dict(content),
        text=None if data.get("text") is None else str(data["text"]),
        asset_path=None if data.get("assetPath") is None else str(data["assetPath"]),
        fit_mode=str(_required(data, "fitMode")),
        crop=None if crop is None else Rect.from_dict(crop),
        source_element_id=None
        if data.get("sourceElementId") is None
        else str(data["sourceElementId"]),
        line_start=_optional_point(data, "lineStart"),
        line_end=_optional_point(data, "lineEnd"),
        table_rows=_table_rows(data.get("tableRows")),
        group_frame=None if data.get("groupFrame") is None else Rect.from_dict(data["groupFrame"]),
    )


def _optional_point(data: dict[str, Any], key: str) -> Point | None:
    value = data.get(key)
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"{key} がオブジェクトではない")
    return Point.from_dict(value)


def project_from_dict(data: dict[str, Any]) -> Project:
    version = _accept_schema(_required(data, "schemaVersion"))
    content_master = _content_from_dict(_required(data, "contentMaster"))
    slide = _slide_from_dict(_required(data, "slide"))
    layouts = [_layout_from_dict(item) for item in data.get("layouts", [])]
    report_slides = [_report_slide_from_dict(item) for item in data.get("slides", [])]
    active_slide_id = None if data.get("activeSlideId") is None else str(data["activeSlideId"])
    if not report_slides and data.get("pages"):
        layouts, report_slides, active_slide_id = _slides_from_pages(data)
    if report_slides:
        active = next((item for item in report_slides if item.id == active_slide_id), report_slides[0])
        layout = next((item for item in layouts if item.id == active.layout_id), None)
        if layout is None:
            raise ValueError("スライドのレイアウトが見つからない")
        content_master = layout.content_master
        slide = active.slide
        active_slide_id = active.id
    return Project(
        schema_version=int(version),
        design_master=_design_from_dict(_required(data, "designMaster")),
        content_master=content_master,
        assets=[_asset_from_dict(item) for item in _required(data, "assets")],
        slide=slide,
        datasets=[_dataset_from_dict(item) for item in data.get("datasets", [])],
        layouts=layouts,
        report_slides=report_slides,
        active_slide_id=active_slide_id,
    )


def _layout_to_dict(layout: LayoutDefinition) -> dict[str, Any]:
    return {
        "id": layout.id,
        "name": layout.name,
        "contentMaster": _content_to_dict(layout.content_master),
    }


def _layout_from_dict(data: dict[str, Any]) -> LayoutDefinition:
    return LayoutDefinition(
        id=str(_required(data, "id")),
        name=str(_required(data, "name")),
        content_master=_content_from_dict(_required(data, "contentMaster")),
    )


def _report_slide_to_dict(item: ReportSlide) -> dict[str, Any]:
    return {
        "id": item.id,
        "name": item.name,
        "layoutId": item.layout_id,
        "slide": _slide_to_dict(item.slide),
    }


def _report_slide_from_dict(data: dict[str, Any]) -> ReportSlide:
    return ReportSlide(
        id=str(_required(data, "id")),
        name=str(_required(data, "name")),
        layout_id=str(_required(data, "layoutId")),
        slide=_slide_from_dict(_required(data, "slide")),
    )


def _slides_from_pages(data: dict[str, Any]) -> tuple[list[LayoutDefinition], list[ReportSlide], str | None]:
    """以前の「1ページが1レイアウト」を、スライドとレイアウトの参照へ読み替える。"""
    layouts: list[LayoutDefinition] = []
    slides: list[ReportSlide] = []
    for index, raw in enumerate(data.get("pages", []), start=1):
        if not isinstance(raw, dict):
            continue
        layout_id = f"layout-{index}"
        content = _content_from_dict(_required(raw, "contentMaster"))
        layouts.append(LayoutDefinition(id=layout_id, name=str(_required(raw, "name")), content_master=content))
        slide = _slide_from_dict(_required(raw, "slide"))
        slide.content_master_id = content.id
        slides.append(
            ReportSlide(
                id=str(_required(raw, "id")),
                name=str(_required(raw, "name")),
                layout_id=layout_id,
                slide=slide,
            )
        )
    active = data.get("activePageId")
    return layouts, slides, None if active is None else str(active)


def _dataset_to_dict(dataset: Dataset) -> dict[str, Any]:
    return {
        "id": dataset.id,
        "name": dataset.name,
        "assetIds": list(dataset.asset_ids),
    }


def _dataset_from_dict(data: dict[str, Any]) -> Dataset:
    return Dataset(
        id=str(_required(data, "id")),
        name=str(_required(data, "name")),
        asset_ids=[str(item) for item in data.get("assetIds", [])],
    )


def _design_to_dict(design: DesignMaster) -> dict[str, Any]:
    payload = {
        "id": design.id,
        "schemaVersion": design.schema_version,
        "slideWidthPt": design.slide_width_pt,
        "slideHeightPt": design.slide_height_pt,
        "marginPt": design.margin_pt,
    }
    if design.orientation:
        _put_optional(payload, "templatePath", design.template_path)
        payload["orientation"] = design.orientation
        if design.body is not None:
            payload["body"] = design.body.to_dict()
        if design.title_frame is not None:
            payload["titleFrame"] = design.title_frame.to_dict()
        _put_optional(payload, "titleShapeName", design.title_shape_name)
        _put_optional(payload, "titleFont", design.title_font)
        if design.title_font_pt is not None:
            payload["titleFontPt"] = design.title_font_pt
        _put_optional(payload, "titleColor", design.title_color)
        payload["pageTitle"] = design.page_title
        _put_optional(payload, "chromeImage", design.chrome_image)
    return payload


def _design_from_dict(data: dict[str, Any]) -> DesignMaster:
    _check_schema(data)
    body = data.get("body")
    title_frame = data.get("titleFrame")
    return DesignMaster(
        id=str(_required(data, "id")),
        schema_version=SCHEMA_VERSION,
        slide_width_pt=float(_required(data, "slideWidthPt")),
        slide_height_pt=float(_required(data, "slideHeightPt")),
        margin_pt=float(_required(data, "marginPt")),
        template_path=_optional_str(data, "templatePath"),
        orientation=_optional_str(data, "orientation"),
        body=Rect.from_dict(body) if isinstance(body, dict) else None,
        title_frame=Rect.from_dict(title_frame) if isinstance(title_frame, dict) else None,
        title_shape_name=_optional_str(data, "titleShapeName"),
        title_font=_optional_str(data, "titleFont"),
        title_font_pt=None if data.get("titleFontPt") is None else float(data["titleFontPt"]),
        title_color=_optional_str(data, "titleColor"),
        page_title=str(data.get("pageTitle") or "撮像画像"),
        chrome_image=_optional_str(data, "chromeImage"),
    )


def _content_to_dict(master: ContentMaster) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "id": master.id,
        "schemaVersion": master.schema_version,
        "designMasterId": master.design_master_id,
        "name": master.name,
        "root": _element_to_dict(master.root),
    }
    if master.master_rois:
        payload["masterRois"] = [_master_roi_to_dict(item) for item in master.master_rois]
    if master.assignment_rule is not None:
        payload["assignmentRule"] = _rule_to_dict(master.assignment_rule)
    return payload


def _content_from_dict(data: dict[str, Any]) -> ContentMaster:
    _check_schema(data)
    masters = data.get("masterRois", [])
    return ContentMaster(
        id=str(_required(data, "id")),
        schema_version=SCHEMA_VERSION,
        design_master_id=str(_required(data, "designMasterId")),
        name=str(_required(data, "name")),
        root=_element_from_dict(_required(data, "root")),
        master_rois=[_master_roi_from_dict(item) for item in masters],
        assignment_rule=_rule_from_dict(data.get("assignmentRule")),
    )


def _asset_to_dict(asset: Asset) -> dict[str, Any]:
    payload = {
        "id": asset.id,
        "kind": asset.kind,
        "path": asset.path,
        "widthPx": asset.width_px,
        "heightPx": asset.height_px,
        "displayName": asset.display_name,
    }
    _put_optional(payload, "source", asset.source)
    _put_optional(payload, "group", asset.group)
    _put_optional(payload, "task", asset.task)
    _put_optional(payload, "listName", asset.list_name)
    _put_optional(payload, "listComment", asset.list_comment)
    _put_optional(payload, "fileName", asset.file_name)
    if asset.note:
        payload["note"] = asset.note
    if asset.list_index is not None:
        payload["listIndex"] = asset.list_index
    return payload


def _asset_from_dict(data: dict[str, Any]) -> Asset:
    kind = str(_required(data, "kind"))
    if kind != "image":
        raise ValueError(f"unsupported asset kind: {kind}")
    return Asset(
        id=str(_required(data, "id")),
        kind="image",
        path=str(_required(data, "path")),
        width_px=int(_required(data, "widthPx")),
        height_px=int(_required(data, "heightPx")),
        display_name=str(_required(data, "displayName")),
        source=_optional_str(data, "source"),
        group=_optional_str(data, "group"),
        task=_optional_str(data, "task"),
        list_name=_optional_str(data, "list_name") if "list_name" in data else _optional_str(data, "listName"),
        list_comment=_optional_str(data, "listComment"),
        list_index=None if data.get("listIndex") is None else int(data["listIndex"]),
        file_name=_optional_str(data, "fileName"),
        note=str(data.get("note") or ""),
    )


def _slide_to_dict(slide: SlideInstance) -> dict[str, Any]:
    payload = {
        "id": slide.id,
        "contentMasterId": slide.content_master_id,
        "bindings": [
            {
                "elementId": binding.element_id,
                "assetId": binding.asset_id,
                "text": binding.text,
            }
            for binding in slide.bindings
        ],
        "rois": [_roi_to_dict(roi) for roi in slide.rois],
    }
    if slide.title:
        payload["title"] = slide.title
    return payload


def _slide_from_dict(data: dict[str, Any]) -> SlideInstance:
    bindings: list[Binding] = []
    for item in _required(data, "bindings"):
        bindings.append(
            Binding(
                element_id=str(_required(item, "elementId")),
                asset_id=None if item.get("assetId") is None else str(item["assetId"]),
                text=None if item.get("text") is None else str(item["text"]),
            )
        )
    rois: list[Roi] = []
    for item in data.get("rois", []):
        rois.append(_roi_from_dict(item))
    return SlideInstance(
        id=str(_required(data, "id")),
        content_master_id=str(_required(data, "contentMasterId")),
        bindings=bindings,
        rois=rois,
        title=str(data.get("title") or ""),
    )


def _roi_to_dict(roi: Roi) -> dict[str, Any]:
    payload = {
        "id": roi.id,
        "name": roi.name,
        "sourceElementId": roi.source_element_id,
        "zoomElementId": roi.zoom_element_id,
        "x": roi.x,
        "y": roi.y,
        "width": roi.width,
        "height": roi.height,
        "coordSpace": roi.coord_space.value,
        "note": roi.note,
    }
    if roi.note_dx is not None and roi.note_dy is not None:
        payload["noteDx"] = roi.note_dx
        payload["noteDy"] = roi.note_dy
    if roi.master_roi_id is not None:
        payload["masterRoiId"] = roi.master_roi_id
    if roi.inheritance != Inheritance.DETACHED:
        payload["inheritance"] = roi.inheritance.value
        payload["dx"] = roi.dx
        payload["dy"] = roi.dy
        payload["dw"] = roi.dw
        payload["dh"] = roi.dh
    return payload


def _roi_from_dict(data: dict[str, Any]) -> Roi:
    zoom_id = data.get("zoomElementId")
    return Roi(
        id=str(_required(data, "id")),
        name=str(_required(data, "name")),
        source_element_id=str(_required(data, "sourceElementId")),
        zoom_element_id=None if zoom_id is None else str(zoom_id),
        x=float(_required(data, "x")),
        y=float(_required(data, "y")),
        width=float(_required(data, "width")),
        height=float(_required(data, "height")),
        coord_space=CoordSpace(str(data.get("coordSpace", CoordSpace.NORMALIZED.value))),
        note=str(data.get("note", "")),
        note_dx=_optional_offset(data, "noteDx"),
        note_dy=_optional_offset(data, "noteDy"),
        master_roi_id=None if data.get("masterRoiId") is None else str(data["masterRoiId"]),
        inheritance=Inheritance(str(data.get("inheritance", Inheritance.DETACHED.value))),
        dx=float(data.get("dx", 0.0)),
        dy=float(data.get("dy", 0.0)),
        dw=float(data.get("dw", 0.0)),
        dh=float(data.get("dh", 0.0)),
    )


def _table_rows(value: Any) -> list[list[str]] | None:
    if value is None:
        return None
    if not isinstance(value, list):
        raise ValueError("tableRows が配列ではない")
    return [[str(cell) for cell in row] for row in value]


def _master_roi_to_dict(roi: MasterRoi) -> dict[str, Any]:
    return {
        "id": roi.id,
        "name": roi.name,
        "sourceElementId": roi.source_element_id,
        "x": roi.x,
        "y": roi.y,
        "width": roi.width,
        "height": roi.height,
        "coordSpace": roi.coord_space.value,
        "note": roi.note,
    }


def _master_roi_from_dict(data: dict[str, Any]) -> MasterRoi:
    return MasterRoi(
        id=str(_required(data, "id")),
        name=str(_required(data, "name")),
        source_element_id=str(_required(data, "sourceElementId")),
        x=float(_required(data, "x")),
        y=float(_required(data, "y")),
        width=float(_required(data, "width")),
        height=float(_required(data, "height")),
        coord_space=CoordSpace(str(data.get("coordSpace", CoordSpace.NORMALIZED.value))),
        note=str(data.get("note", "")),
    )


def _optional_offset(data: dict[str, Any], key: str) -> float | None:
    dx = data.get("noteDx")
    dy = data.get("noteDy")
    if dx is None or dy is None:
        return None
    value = data.get(key)
    if value is None:
        return None
    return float(value)


def _element_to_dict(element: Element) -> dict[str, Any]:
    if isinstance(element, StackNode):
        payload: dict[str, Any] = {
            "id": element.id,
            "kind": element.kind,
            "direction": element.direction.value,
            "gapPt": element.gap_pt,
            "children": [_element_to_dict(child) for child in element.children],
        }
        if element.track_aspect:
            payload["trackAspect"] = True
        if element.emphasize_first:
            payload["emphasizeFirst"] = True
        return payload
    if isinstance(element, GridNode):
        return {
            "id": element.id,
            "kind": element.kind,
            "columns": element.columns,
            "gapPt": element.gap_pt,
            "children": [_element_to_dict(child) for child in element.children],
        }
    if isinstance(element, ImageFrameNode):
        payload = {
            "id": element.id,
            "kind": element.kind,
            "roleId": element.role_id,
            "displayName": element.display_name,
            "fitMode": element.fit_mode.value,
        }
        if element.free_rect is not None:
            payload["freeRect"] = element.free_rect.to_dict()
        return payload
    if isinstance(element, TextNode):
        return {
            "id": element.id,
            "kind": element.kind,
            "roleId": element.role_id,
            "displayName": element.display_name,
            "text": element.text,
            "heightPt": element.height_pt,
        }
    if isinstance(element, TableNode):
        return {
            "id": element.id,
            "kind": element.kind,
            "displayName": element.display_name,
            "headers": list(element.headers),
            "rows": [list(row) for row in element.rows],
            "heightPt": element.height_pt,
        }
    raise TypeError(f"unknown element: {type(element)!r}")


def _element_from_dict(data: dict[str, Any]) -> Element:
    kind = str(_required(data, "kind"))
    if kind == "stack":
        return StackNode(
            id=str(_required(data, "id")),
            direction=StackDirection(str(_required(data, "direction"))),
            gap_pt=float(_required(data, "gapPt")),
            track_aspect=bool(data.get("trackAspect", False)),
            emphasize_first=bool(data.get("emphasizeFirst", False)),
            children=[_element_from_dict(child) for child in _required(data, "children")],
        )
    if kind == "grid":
        return GridNode(
            id=str(_required(data, "id")),
            columns=int(_required(data, "columns")),
            gap_pt=float(_required(data, "gapPt")),
            children=[_element_from_dict(child) for child in _required(data, "children")],
        )
    if kind == "image_frame":
        free = data.get("freeRect")
        return ImageFrameNode(
            id=str(_required(data, "id")),
            role_id=str(_required(data, "roleId")),
            display_name=str(_required(data, "displayName")),
            fit_mode=FitMode(str(_required(data, "fitMode"))),
            free_rect=None if free is None else Rect.from_dict(free),
        )
    if kind == "text":
        return TextNode(
            id=str(_required(data, "id")),
            role_id=str(_required(data, "roleId")),
            display_name=str(_required(data, "displayName")),
            text=str(_required(data, "text")),
            height_pt=float(_required(data, "heightPt")),
        )
    if kind == "table":
        return TableNode(
            id=str(_required(data, "id")),
            display_name=str(_required(data, "displayName")),
            headers=[str(item) for item in _required(data, "headers")],
            rows=[[str(cell) for cell in row] for row in _required(data, "rows")],
            height_pt=float(_required(data, "heightPt")),
        )
    raise ValueError(f"unknown element kind: {kind}")


def _put_optional(payload: dict[str, Any], key: str, value: str | None) -> None:
    if value:
        payload[key] = value


def _optional_str(data: dict[str, Any], key: str) -> str | None:
    value = data.get(key)
    if value is None or value == "":
        return None
    return str(value)


def _accept_schema(version: Any) -> int:
    if version not in READABLE_SCHEMA_VERSIONS:
        raise ValueError(f"unsupported schemaVersion: {version}")
    return SCHEMA_VERSION


def _frame_ref_to_dict(ref: FrameRef) -> dict[str, Any]:
    return {
        "elementId": ref.element_id,
        "frameIndex": ref.frame_index,
        "listBy": ref.list_by,
        "listKey": ref.list_key,
        "itemNumber": ref.item_number,
        "labelTemplate": ref.label_template,
    }


def _frame_ref_from_dict(data: dict[str, Any], index: int) -> FrameRef:
    return FrameRef(
        element_id=str(data.get("elementId") or ""),
        frame_index=int(data.get("frameIndex", index)),
        list_by=str(data.get("listBy") or "comment"),
        list_key=str(data.get("listKey") or ""),
        item_number=int(_required(data, "itemNumber")),
        label_template=str(data.get("labelTemplate") or ""),
    )


def _rule_to_dict(rule: AssignmentRule) -> dict[str, Any]:
    return {
        "mode": rule.mode,
        "offset": rule.offset,
        "stride": rule.stride,
        "perSlide": rule.per_slide,
        "step": rule.step,
        "mappings": [
            {"elementId": item.element_id, "itemNumber": item.item_number} for item in rule.mappings
        ],
        "pattern": [_frame_ref_to_dict(item) for item in rule.pattern],
        "rangeFrom": rule.range_from,
        "rangeTo": rule.range_to,
        "titleTemplate": rule.title_template,
        "textTemplates": [
            {"elementId": item.element_id, "template": item.template} for item in rule.text_templates
        ],
        "overrides": [
            {
                "slideOrdinal": item.slide_ordinal,
                "frames": [_frame_ref_to_dict(ref) for ref in item.frames],
            }
            for item in rule.overrides
        ],
    }


def _rule_from_dict(data: Any) -> AssignmentRule | None:
    if data is None:
        return None
    if not isinstance(data, dict):
        raise ValueError("割付ルールがオブジェクトではない")
    mappings: list[FrameMapping] = []
    for item in data.get("mappings", []):
        if not isinstance(item, dict):
            raise ValueError("割付ルールの枠がオブジェクトではない")
        mappings.append(
            FrameMapping(
                element_id=str(_required(item, "elementId")),
                item_number=int(_required(item, "itemNumber")),
            )
        )
    pattern = [
        _frame_ref_from_dict(item, index)
        for index, item in enumerate(data.get("pattern") or [])
        if isinstance(item, dict)
    ]
    overrides: list[SlideOverride] = []
    for item in data.get("overrides") or []:
        if not isinstance(item, dict):
            continue
        overrides.append(
            SlideOverride(
                slide_ordinal=int(item.get("slideOrdinal", 0)),
                frames=[
                    _frame_ref_from_dict(ref, index)
                    for index, ref in enumerate(item.get("frames") or [])
                    if isinstance(ref, dict)
                ],
            )
        )
    text_templates = [
        TextTemplate(element_id=str(item.get("elementId") or ""), template=str(item.get("template") or ""))
        for item in data.get("textTemplates") or []
        if isinstance(item, dict) and str(item.get("template") or "")
    ]
    range_to = data.get("rangeTo")
    offset = int(data.get("offset", 1))
    stride = int(data.get("stride", 1))
    per_slide = int(data.get("perSlide", max(len(pattern), 1)))
    mode = str(data.get("mode") or "pattern")
    if not pattern:
        if mode == "explicit" and mappings:
            pattern = [
                FrameRef(item.element_id, index, "position", "1", item.item_number)
                for index, item in enumerate(mappings)
            ]
        else:
            count = per_slide if per_slide > 0 else 1
            pattern = [
                FrameRef("", index, "position", "1", offset + index) for index in range(count)
            ]
        mode = "pattern"
    return AssignmentRule(
        mode=mode,
        offset=offset,
        stride=stride,
        per_slide=per_slide,
        mappings=mappings,
        step=int(data.get("step", stride)),
        pattern=pattern,
        overrides=overrides,
        range_from=int(data.get("rangeFrom", 1)),
        range_to=None if range_to in (None, "") else int(range_to),
        title_template=str(data.get("titleTemplate") or ""),
        text_templates=text_templates,
    )


def _check_schema(data: dict[str, Any]) -> None:
    _accept_schema(_required(data, "schemaVersion"))


def _required(data: dict[str, Any], key: str) -> Any:
    if key not in data:
        raise ValueError(f"missing field: {key}")
    return data[key]
