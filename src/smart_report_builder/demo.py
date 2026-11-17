"""画像2枚と説明文の1スライドを output/sample_a.pptx に書く。"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

from smart_report_builder.layout import layout_slide
from smart_report_builder.project_store import (
    load_project,
    missing_asset_paths,
    save_layout_result,
    save_project,
)
from smart_report_builder.models import (
    GAP_PT,
    TEXT_HEIGHT_PT,
    Asset,
    Binding,
    ContentMaster,
    CoordSpace,
    DesignMaster,
    FitMode,
    ImageFrameNode,
    LayoutResult,
    Project,
    Roi,
    SlideInstance,
    StackDirection,
    StackNode,
    TextNode,
)
from smart_report_builder.pptx_writer import write_pptx

DESIGN_ID = "design-16x9"
MASTER_ID = "master-two-images"
SLIDE_ID = "slide-1"
STACK_ROOT_ID = "stack-root"
STACK_IMAGES_ID = "stack-images"
FRAME_OVERALL_ID = "frame-overall"
FRAME_COMPARE_ID = "frame-compare"
ZOOM_FRAME_ID = "frame-zoom"
ROI_ID = "roi-1"
TEXT_ID = "text-caption"
ROI_MASTER_ID = "master-roi"
ROI_SLIDE_ID = "slide-roi"
ASSET_OVERALL_ID = "asset-overall"
ASSET_COMPARE_ID = "asset-compare"

DEFAULT_CAPTION = (
    "これは編集可能な説明文です。"
    "レイアウトの都合で短縮、削除してはいけません。"
    "画像は縦横比を維持し、枠内に Contain で配置します。"
)


def build_two_image_project(
    overall_path: Path | str = "overall.png",
    comparison_path: Path | str = "comparison.png",
    overall_px: tuple[int, int] = (800, 400),
    comparison_px: tuple[int, int] = (400, 800),
    *,
    caption: str = DEFAULT_CAPTION,
    assign_images: bool = True,
    text_height_pt: float = TEXT_HEIGHT_PT,
    stack_gap_pt: float = GAP_PT,
    image_gap_pt: float = GAP_PT,
    fit_mode: FitMode = FitMode.CONTAIN,
    bindings: list[Binding] | None = None,
) -> Project:
    """意味付き画像枠2つと説明文を持つマスター。role 名は表示用で、配置は木構造で決まる。"""
    assets: list[Asset] = []
    default_bindings: list[Binding] = []
    if assign_images:
        assets = [
            Asset(
                id=ASSET_OVERALL_ID,
                path=str(Path(overall_path).resolve()),
                width_px=overall_px[0],
                height_px=overall_px[1],
                display_name="全体画像",
            ),
            Asset(
                id=ASSET_COMPARE_ID,
                path=str(Path(comparison_path).resolve()),
                width_px=comparison_px[0],
                height_px=comparison_px[1],
                display_name="比較画像",
            ),
        ]
        default_bindings = [
            Binding(element_id=FRAME_OVERALL_ID, asset_id=ASSET_OVERALL_ID),
            Binding(element_id=FRAME_COMPARE_ID, asset_id=ASSET_COMPARE_ID),
        ]

    root = StackNode(
        id=STACK_ROOT_ID,
        direction=StackDirection.VERTICAL,
        gap_pt=stack_gap_pt,
        children=[
            StackNode(
                id=STACK_IMAGES_ID,
                direction=StackDirection.HORIZONTAL,
                gap_pt=image_gap_pt,
                children=[
                    ImageFrameNode(
                        id=FRAME_OVERALL_ID,
                        role_id="overall",
                        display_name="全体画像",
                        fit_mode=fit_mode,
                    ),
                    ImageFrameNode(
                        id=FRAME_COMPARE_ID,
                        role_id="comparison",
                        display_name="比較画像",
                        fit_mode=fit_mode,
                    ),
                ],
            ),
            TextNode(
                id=TEXT_ID,
                role_id="caption",
                display_name="説明",
                text=caption,
                height_pt=text_height_pt,
            ),
        ],
    )
    return Project(
        design_master=DesignMaster(id=DESIGN_ID),
        content_master=ContentMaster(
            id=MASTER_ID,
            design_master_id=DESIGN_ID,
            name="画像2枚と説明",
            root=root,
        ),
        assets=assets,
        slide=SlideInstance(
            id=SLIDE_ID,
            content_master_id=MASTER_ID,
            bindings=default_bindings if bindings is None else bindings,
        ),
    )


def build_roi_project(
    overall_path: Path | str,
    overall_px: tuple[int, int] = (800, 400),
    *,
    caption: str = DEFAULT_CAPTION,
    roi: Roi | None = None,
) -> Project:
    """全体画像、その ROI、拡大画像枠、説明文。ROI の継承はまだしない。"""
    if roi is None:
        roi = Roi(
            id=ROI_ID,
            name="ROI",
            source_element_id=FRAME_OVERALL_ID,
            zoom_element_id=ZOOM_FRAME_ID,
            x=0.1,
            y=0.2,
            width=0.2,
            height=0.6,
            coord_space=CoordSpace.NORMALIZED,
        )
    root = StackNode(
        id=STACK_ROOT_ID,
        direction=StackDirection.VERTICAL,
        gap_pt=GAP_PT,
        children=[
            StackNode(
                id=STACK_IMAGES_ID,
                direction=StackDirection.HORIZONTAL,
                gap_pt=GAP_PT,
                children=[
                    ImageFrameNode(
                        id=FRAME_OVERALL_ID,
                        role_id="overall",
                        display_name="全体画像",
                        fit_mode=FitMode.CONTAIN,
                    ),
                    ImageFrameNode(
                        id=ZOOM_FRAME_ID,
                        role_id="zoom",
                        display_name="拡大画像",
                        fit_mode=FitMode.ROI,
                    ),
                ],
            ),
            TextNode(
                id=TEXT_ID,
                role_id="caption",
                display_name="説明",
                text=caption,
                height_pt=TEXT_HEIGHT_PT,
            ),
        ],
    )
    return Project(
        design_master=DesignMaster(id=DESIGN_ID),
        content_master=ContentMaster(
            id=ROI_MASTER_ID,
            design_master_id=DESIGN_ID,
            name="全体画像とROI拡大",
            root=root,
        ),
        assets=[
            Asset(
                id=ASSET_OVERALL_ID,
                path=str(Path(overall_path).resolve()),
                width_px=overall_px[0],
                height_px=overall_px[1],
                display_name="全体画像",
            )
        ],
        slide=SlideInstance(
            id=ROI_SLIDE_ID,
            content_master_id=ROI_MASTER_ID,
            bindings=[Binding(element_id=FRAME_OVERALL_ID, asset_id=ASSET_OVERALL_ID)],
            rois=[roi],
        ),
    )


def build_two_zoom_project(
    overall_path: Path | str,
    overall_px: tuple[int, int] = (800, 400),
) -> Project:
    """拡大枠が二つの配置。それぞれの枠に別の ROI を連動する。"""
    project = build_roi_project(overall_path, overall_px)
    images = project.content_master.root.children[0]
    if not isinstance(images, StackNode):
        raise TypeError("画像の並びが見つからない")
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
            zoom_element_id="frame-zoom-b",
            x=0.5,
            y=0.1,
            width=0.3,
            height=0.4,
        )
    )
    return project


def main() -> None:
    root = _project_root()
    fixture_dir = root / "output" / "fixtures"
    fixture_dir.mkdir(parents=True, exist_ok=True)
    overall = fixture_dir / "overall.png"
    comparison = fixture_dir / "comparison.png"
    _write_dummy_png(overall, 800, 400, (47, 111, 176))
    _write_dummy_png(comparison, 400, 800, (196, 122, 48))
    before = {path: path.read_bytes() for path in (overall, comparison)}

    project = build_two_image_project(
        overall,
        comparison,
        _read_size(overall),
        _read_size(comparison),
    )
    _export_project(root, project, "sample_a")
    _export_project(root, build_roi_project(overall, _read_size(overall)), "sample_roi")
    _export_project(root, build_two_zoom_project(overall, _read_size(overall)), "sample_zooms")

    for path, blob in before.items():
        if path.read_bytes() != blob:
            raise RuntimeError(f"source image was modified: {path.name}")


def _export_project(root: Path, project: Project, stem: str) -> LayoutResult:
    project_path = root / "output" / f"{stem}.project.json"
    save_project(project, project_path)
    loaded = load_project(project_path)
    original = layout_slide(project)
    result = layout_slide(loaded)
    if _layout_signature(original) != _layout_signature(result):
        raise RuntimeError(f"reloaded project produced a different layout: {stem}")
    layout_path = root / "output" / f"{stem}.layout.json"
    save_layout_result(result, layout_path)
    destination = root / "output" / f"{stem}.pptx"
    write_pptx(result, destination)
    print(project_path)
    print(layout_path)
    print(destination)
    print(f"{stem} elements={len(result.elements)} violations={len(result.violations)}")
    for missing in missing_asset_paths(loaded):
        print(f"missing asset {Path(missing).name}")
    for violation in result.violations:
        print(f"violation {violation.code} {violation.element_id}")
    return result


def _layout_signature(result: LayoutResult):
    return [
        (item.element_id, item.kind, item.frame, item.content_rect, item.crop, item.text)
        for item in result.elements
    ]


def _project_root() -> Path:
    candidate = Path(__file__).resolve().parents[2]
    if (candidate / "pyproject.toml").is_file():
        return candidate
    return Path.cwd()


def _write_dummy_png(path: Path, width: int, height: int, color: tuple[int, int, int]) -> None:
    image = Image.new("RGB", (width, height), color)
    draw = ImageDraw.Draw(image)
    draw.rectangle((20, 20, width - 20, height - 20), outline=(255, 255, 255), width=8)
    image.save(path, format="PNG")


def _read_size(path: Path) -> tuple[int, int]:
    with Image.open(path) as image:
        return image.size


if __name__ == "__main__":
    main()
