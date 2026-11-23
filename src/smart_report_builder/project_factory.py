"""画像と説明文を持つ新しいプロジェクトを作る。

配置の計算は layout に任せ、このモジュールはマスターの木を組み立てるだけ。
素材は登録しない。仮プレビューの状態で保存できる。
"""

from __future__ import annotations

from smart_report_builder.demo import DEFAULT_CAPTION
from smart_report_builder.imaging_template import (
    DEFAULT_PAGE_TITLE,
    bundled_template,
    read_imaging_template,
)
from smart_report_builder.models import (
    GAP_PT,
    TEXT_HEIGHT_PT,
    ContentMaster,
    DesignMaster,
    FitMode,
    GridNode,
    ImageFrameNode,
    Project,
    SlideInstance,
    StackDirection,
    StackNode,
    TextNode,
)

_ARRANGEMENTS = {"horizontal", "vertical", "grid"}
_TEMPLATES = {"images", "overall-zoom"}
_PAPERS = {"16x9", "portrait", "landscape"}


def create_report(
    *,
    image_count: int = 2,
    arrangement: str = "horizontal",
    template: str = "images",
    caption: str = DEFAULT_CAPTION,
    paper: str = "16x9",
) -> Project:
    if arrangement not in _ARRANGEMENTS:
        raise ValueError("配置は縦、横、格子のいずれかです")
    if template not in _TEMPLATES:
        raise ValueError("テンプレートは画像、または全体と拡大です")
    if paper not in _PAPERS:
        raise ValueError("用紙は 16:9、縦、横のいずれかです")
    if template == "overall-zoom":
        frames = [
            ImageFrameNode(
                id="frame-overall",
                role_id="overall",
                display_name="全体画像",
                fit_mode=FitMode.CONTAIN,
            ),
            ImageFrameNode(
                id="frame-zoom",
                role_id="zoom",
                display_name="拡大画像",
                fit_mode=FitMode.ROI,
            ),
        ]
        master_id = "master-overall-zoom"
        name = "全体画像と拡大"
    else:
        if image_count < 2 or image_count > 4:
            raise ValueError("画像枠は2〜4枚です")
        frames = [_image_frame(index, image_count) for index in range(image_count)]
        master_id = "master-images"
        name = f"画像{image_count}枚と説明"
    root = StackNode(
        id="stack-root",
        direction=StackDirection.VERTICAL,
        gap_pt=GAP_PT,
        children=[
            _image_block(arrangement, frames),
            TextNode(
                id="text-caption",
                role_id="caption",
                display_name="説明",
                text=caption,
                height_pt=TEXT_HEIGHT_PT,
                font_pt=12.0,
            ),
        ],
    )
    design = _design_for_paper(paper)
    return Project(
        design_master=design,
        content_master=ContentMaster(
            id=master_id,
            design_master_id=design.id,
            name=name,
            root=root,
        ),
        assets=[],
        slide=SlideInstance(
            id="slide-1",
            content_master_id=master_id,
            bindings=[],
            title=DEFAULT_PAGE_TITLE if design.orientation else "",
        ),
    )


def _design_for_paper(paper: str) -> DesignMaster:
    if paper == "16x9":
        return DesignMaster(id="design-16x9")
    spec = read_imaging_template(bundled_template(paper))
    return DesignMaster(
        id=f"design-{paper}",
        slide_width_pt=spec.slide_width_pt,
        slide_height_pt=spec.slide_height_pt,
        margin_pt=0,
        template_path=str(bundled_template(paper)),
        orientation=paper,
        body=spec.body,
        title_frame=spec.title_frame,
        title_shape_name=spec.title_shape_name,
        title_font=spec.title_font,
        title_font_pt=spec.title_font_pt,
        title_color=spec.title_color,
        page_title=DEFAULT_PAGE_TITLE,
    )


def _image_frame(index: int, image_count: int) -> ImageFrameNode:
    if image_count == 2 and index == 0:
        return ImageFrameNode(
            id="frame-overall",
            role_id="overall",
            display_name="全体画像",
        )
    if image_count == 2 and index == 1:
        return ImageFrameNode(
            id="frame-compare",
            role_id="comparison",
            display_name="比較画像",
        )
    number = index + 1
    return ImageFrameNode(
        id=f"frame-{number}",
        role_id="image",
        display_name=f"画像{number}",
    )


def _image_block(arrangement: str, frames: list[ImageFrameNode]) -> StackNode | GridNode:
    if arrangement == "grid":
        return GridNode(
            id="grid-images",
            columns=1 if len(frames) <= 1 else 2,
            gap_pt=GAP_PT,
            children=list(frames),
        )
    direction = StackDirection.VERTICAL if arrangement == "vertical" else StackDirection.HORIZONTAL
    return StackNode(
        id="stack-images",
        direction=direction,
        gap_pt=GAP_PT,
        track_aspect=True,
        children=list(frames),
    )
