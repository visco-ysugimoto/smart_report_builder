"""新 UI 向けの `cli/` サブコマンドを通した統合スモークテスト。

Flutter 側は subprocess 経由で `python -m smart_report_builder.roi_edit <cmd>` を叩く。
このテストは `cli/` モジュールの `run(argv)` を直接呼んでフロー全体を確認する:

  1. 新規プロジェクトを保存
  2. pick-layout でプリセットを選ぶ
  3. pick-roles で枠の役割を変える
  4. register-source で素材を並びの番号付きで登録
  5. set-templates でタイトル / 見解テンプレートを設定
  6. expand-slides で登録した素材から N 枚に展開
  7. edit-slide で特定スライドのタイトルと見解を書き換え
  8. save-pptx で任意パスに PPTX を書き出す
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image
from pptx import Presentation

from smart_report_builder.cli import (
    add_source,
    expand,
    export_pptx,
    pick_layout,
    pick_roles,
    pick_templates,
    update_slide,
)
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import FitMode, ImageFrameNode, TextNode
from smart_report_builder.project_factory import create_report
from smart_report_builder.project_store import load_project, save_project


def _png(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (16, 16), (40, 80, 120)).save(path, format="PNG")
    return path


def _write_records(path: Path, image_paths: list[Path]) -> Path:
    payload = [
        {
            "path": str(image),
            "source": "folder",
            "listIndex": index,
            "fileName": image.name,
        }
        for index, image in enumerate(image_paths, start=1)
    ]
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def _caption_text(root, caption_id: str) -> str | None:
    if isinstance(root, TextNode) and root.id == caption_id:
        return root.text
    for child in getattr(root, "children", []) or []:
        found = _caption_text(child, caption_id)
        if found is not None:
            return found
    return None


def _save_initial_project(tmp_path: Path) -> Path:
    project = create_report()
    project_path = tmp_path / "project.json"
    save_project(project, project_path)
    return project_path


def test_pick_layout_rebuilds_master_from_preset(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)

    code = pick_layout.run([str(project_path), "--preset", "horizontal-3"])

    assert code == 0
    project = load_project(project_path)
    frames = [
        child
        for child in _walk(project.content_master.root)
        if isinstance(child, ImageFrameNode)
    ]
    assert len(frames) == 3
    assert {frame.fit_mode for frame in frames} == {FitMode.CONTAIN}
    assert [frame.display_name for frame in frames] == ["画像1", "画像2", "画像3"]

    assert pick_layout.run([str(project_path), "--preset", "overall-zoom"]) == 0
    project = load_project(project_path)
    frames = [
        child
        for child in _walk(project.content_master.root)
        if isinstance(child, ImageFrameNode)
    ]
    assert [frame.role_id for frame in frames] == ["image", "zoom"]
    assert [frame.display_name for frame in frames] == ["画像1", "拡大画像"]


def test_pick_layout_supports_horizontal_4_and_grid_3x3(tmp_path: Path):
    # 1x4 (横4枚) と 3x3 グリッドなど、拡張したプリセットが正しく枠を作ることを確認する。
    for preset, expected_count in [
        ("horizontal-4", 4),
        ("vertical-3", 3),
        ("grid-2x3", 6),
        ("grid-3x2", 6),
        ("grid-3x3", 9),
        ("overall-compare-3", 4),
    ]:
        project_path = _save_initial_project(tmp_path / preset)
        code = pick_layout.run([str(project_path), "--preset", preset])
        assert code == 0, f"preset {preset} failed"
        project = load_project(project_path)
        frames = [
            node
            for node in _walk(project.content_master.root)
            if isinstance(node, ImageFrameNode)
        ]
        assert len(frames) == expected_count, f"{preset}: want {expected_count} frames"
        # 枠 ID は frame-1..N で一意
        assert len({frame.id for frame in frames}) == expected_count


def test_pick_roles_switches_a_single_frame_to_zoom(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    pick_layout.run([str(project_path), "--preset", "horizontal-2"])

    code = pick_roles.run(
        [str(project_path), "--frame", "frame-2", "--role", "zoom"]
    )

    assert code == 0
    project = load_project(project_path)
    frame = next(
        node
        for node in _walk(project.content_master.root)
        if isinstance(node, ImageFrameNode) and node.id == "frame-2"
    )
    assert frame.role_id == "zoom"
    assert frame.fit_mode == FitMode.ROI


def test_two_zoom_frames_in_a_grid_enlarge_the_chosen_sources(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "grid-2x2"]) == 0
    assert pick_roles.run([str(project_path), "--frame", "frame-3", "--role", "zoom"]) == 0
    assert pick_roles.run([str(project_path), "--frame", "frame-4", "--role", "zoom"]) == 0
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 3)]
    records_path = _write_records(tmp_path / "records.json", images)
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0
    project = load_project(project_path)
    assert update_slide.run([str(project_path), "--bind", "frame-1", project.assets[0].id]) == 0
    assert update_slide.run([str(project_path), "--bind", "frame-2", project.assets[1].id]) == 0
    assert update_slide.run([str(project_path), "--zoom-from", "frame-3", "frame-1"]) == 0
    assert update_slide.run([str(project_path), "--zoom-from", "frame-4", "frame-2"]) == 0

    placed = {item.element_id: item for item in layout_slide(load_project(project_path)).elements}
    assert placed["frame-3"].source_element_id == "frame-1"
    assert placed["frame-4"].source_element_id == "frame-2"
    assert placed["frame-3"].asset_path
    assert placed["frame-4"].asset_path
    assert placed["frame-3"].crop is not None
    assert placed["frame-3"].crop.width == 0.5


def test_zoom_region_moves_on_the_selected_slide_only(tmp_path: Path):
    """拡大範囲は中央固定ではなく、スライドごとに左上を動かせる。"""
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0
    assert pick_roles.run([str(project_path), "--frame", "frame-2", "--role", "zoom"]) == 0
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 3)]
    records_path = _write_records(tmp_path / "records.json", images)
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0
    project = load_project(project_path)
    assert update_slide.run([str(project_path), "--bind", "frame-1", project.assets[0].id]) == 0
    assert update_slide.run([str(project_path), "--zoom-from", "frame-2", "frame-1"]) == 0
    assert update_slide.run([str(project_path), "--zoom-move", "frame-2", "0.1", "0.4"]) == 0

    placed = {item.element_id: item for item in layout_slide(load_project(project_path)).elements}
    roi = next(item for item in placed.values() if item.kind == "roi")
    assert roi.zoom_element_id == "frame-2"
    assert placed["frame-2"].crop.x == 0.1
    assert placed["frame-2"].crop.y == 0.4
    assert placed["frame-2"].crop.width == 0.5

    assert expand.run([str(project_path)]) == 0
    assert update_slide.run(
        [str(project_path), "--slide", "slide-2", "--zoom-move", "frame-2", "0.9", "0.05"]
    ) == 0
    # 幅 0.5 の範囲は右端 0.5 で止まる。
    project = load_project(project_path)
    first = project.report_slides[0].slide.rois[0]
    second = project.report_slides[1].slide.rois[0]
    assert (first.x, first.y) == (0.1, 0.4)
    assert second.x == 0.5
    assert second.y == 0.05

    assert update_slide.run(
        [
            str(project_path),
            "--slide",
            "slide-2",
            "--zoom-rect",
            "frame-2",
            "0.2",
            "0.1",
            "0.3",
            "0.15",
        ]
    ) == 0
    project = load_project(project_path)
    first = project.report_slides[0].slide.rois[0]
    second = project.report_slides[1].slide.rois[0]
    assert (first.x, first.y, first.width, first.height) == (0.1, 0.4, 0.5, 0.5)
    assert (second.x, second.y, second.width, second.height) == (0.2, 0.1, 0.3, 0.15)

    assert expand.run([str(project_path)]) == 0
    project = load_project(project_path)
    kept = project.report_slides[1].slide.rois[0]
    assert kept.x == 0.2
    assert kept.y == 0.1
    assert kept.width == 0.3
    assert kept.height == 0.15
    project.slide = project.report_slides[1].slide
    moved = {item.element_id: item for item in layout_slide(project).elements}
    assert moved["frame-2"].crop.x == 0.2
    assert moved["frame-2"].crop.y == 0.1
    assert moved["frame-2"].crop.width == 0.3
    assert moved["frame-2"].crop.height == 0.15


def test_heading_and_free_text_are_placed_without_covering_the_image(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0
    image = _png(tmp_path / "img_1.png")
    records_path = _write_records(tmp_path / "records.json", [image])
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0
    project = load_project(project_path)
    assert update_slide.run([str(project_path), "--bind", "frame-1", project.assets[0].id]) == 0
    assert update_slide.run([str(project_path), "--heading", "frame-1", "傷の見出し"]) == 0
    assert update_slide.run([str(project_path), "--add-text", "--text", "注記"]) == 0
    assert update_slide.run(
        [str(project_path), "--text-box", "text-free-1", "40", "50", "120", "28"]
    ) == 0

    placed = {item.element_id: item for item in layout_slide(load_project(project_path)).elements}
    frame = placed["frame-1"]
    assert frame.text == "傷の見出し"
    assert frame.label_frame is not None
    assert frame.label_frame.y + frame.label_frame.height <= frame.frame.y + 0.01
    assert frame.content_rect is not None
    assert frame.content_rect.y >= frame.frame.y - 0.01
    assert frame.content_rect.y + frame.content_rect.height <= frame.frame.y + frame.frame.height + 0.01
    note = placed["text-free-1"]
    assert note.text == "注記"
    assert note.frame.x == 40
    assert note.frame.y == 50
    assert note.frame.width == 120
    assert note.frame.height == 28
    laid_out = layout_slide(load_project(project_path))
    assert not any(item.element_id == "text-free-1" for item in laid_out.violations)
    assert update_slide.run([str(project_path), "--heading-place", "frame-1", "below"]) == 0
    assert update_slide.run([str(project_path), "--caption-place", "above"]) == 0
    moved = {item.element_id: item for item in layout_slide(load_project(project_path)).elements}
    headed = moved["frame-1"]
    assert headed.text_anchor == "below"
    assert headed.label_frame is not None
    assert headed.label_frame.y >= headed.frame.y + headed.frame.height - 0.01
    assert moved["text-caption"].frame.y < headed.frame.y
    with_caption = headed.frame.height
    assert update_slide.run([str(project_path), "--caption-use", "off"]) == 0
    assert update_slide.run([str(project_path), "--heading-size", "frame-1", "28"]) == 0
    assert update_slide.run([str(project_path), "--text-size", "text-free-1", "22"]) == 0
    resized = {item.element_id: item for item in layout_slide(load_project(project_path)).elements}
    assert "text-caption" not in resized
    assert resized["frame-1"].frame.height > with_caption
    assert resized["frame-1"].font_pt == 28
    assert resized["frame-1"].label_frame.height > headed.label_frame.height
    assert resized["text-free-1"].font_pt == 22


def test_register_source_adds_assets_with_sequential_indices(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 4)]
    records_path = _write_records(tmp_path / "records.json", images)

    code = add_source.run(
        [str(project_path), "--records", str(records_path)]
    )

    assert code == 0
    project = load_project(project_path)
    assert len(project.assets) == 3
    assert sorted(asset.list_index for asset in project.assets) == [1, 2, 3]
    assert {Path(asset.path).name for asset in project.assets} == {
        "img_1.png",
        "img_2.png",
        "img_3.png",
    }


def test_register_source_without_replace_appends_new_asset(tmp_path: Path):
    """ドロップ時の自動登録では --replace を付けず、既存素材を保ったまま 1 枚追加する。"""
    project_path = _save_initial_project(tmp_path)
    initial = [_png(tmp_path / f"initial_{i}.png") for i in range(1, 3)]
    _write_records(tmp_path / "records.json", initial)
    add_source.run([str(project_path), "--records", str(tmp_path / "records.json")])
    before = load_project(project_path)
    assert len(before.assets) == 2

    # 追加 1 枚を listIndex=3 で追記
    extra = _png(tmp_path / "extra.png")
    extra_records = tmp_path / "extra.json"
    extra_records.write_text(
        json.dumps(
            [{"path": str(extra), "source": "folder", "listIndex": 3, "fileName": extra.name}]
        ),
        encoding="utf-8",
    )
    code = add_source.run(
        [str(project_path), "--records", str(extra_records)]
    )

    assert code == 0
    after = load_project(project_path)
    assert len(after.assets) == 3
    assert sorted(a.list_index for a in after.assets) == [1, 2, 3]
    assert {Path(a.path).name for a in after.assets} == {
        "initial_1.png",
        "initial_2.png",
        "extra.png",
    }


def test_expand_keeps_vtv_tray_order_across_separate_lists(tmp_path: Path):
    """VTV の txt が複数あっても、取り込み順に枠へ載せる。"""
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 5)]
    records = [
        {
            "path": str(images[0]),
            "source": "folder",
            "listIndex": 1,
            "fileName": images[0].name,
            "group": "g01",
            "task": "03",
            "listName": "cap",
            "listComment": "外観",
        },
        {
            "path": str(images[1]),
            "source": "folder",
            "listIndex": 1,
            "fileName": images[1].name,
            "group": "g01",
            "task": "03",
            "listName": "cap",
            "listComment": "拡大",
        },
        {
            "path": str(images[2]),
            "source": "folder",
            "listIndex": 2,
            "fileName": images[2].name,
            "group": "g01",
            "task": "03",
            "listName": "cap",
            "listComment": "外観",
        },
        {
            "path": str(images[3]),
            "source": "folder",
            "listIndex": 2,
            "fileName": images[3].name,
            "group": "g01",
            "task": "03",
            "listName": "cap",
            "listComment": "拡大",
        },
    ]
    records_path = tmp_path / "records.json"
    records_path.write_text(json.dumps(records), encoding="utf-8")
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0

    assert expand.run([str(project_path)]) == 0
    project = load_project(project_path)
    assert len(project.report_slides) == 2
    by_id = {asset.id: Path(asset.path).name for asset in project.assets}

    def bound_names(ordinal: int) -> list[str]:
        slide = project.report_slides[ordinal].slide
        names = []
        for frame_id in ("frame-1", "frame-2"):
            binding = next(item for item in slide.bindings if item.element_id == frame_id)
            names.append(by_id[binding.asset_id])
        return names

    assert bound_names(0) == ["img_1.png", "img_2.png"]
    assert bound_names(1) == ["img_3.png", "img_4.png"]


def test_expand_keeps_the_first_slide_and_continues_in_order(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 5)]
    records_path = _write_records(tmp_path / "records.json", images)
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0
    project = load_project(project_path)
    assert update_slide.run([str(project_path), "--bind", "frame-1", project.assets[0].id]) == 0
    assert update_slide.run([str(project_path), "--bind", "frame-2", project.assets[1].id]) == 0
    # 展開前の再登録でも、置いた画像の割当は残る。
    assert (
        add_source.run(
            [str(project_path), "--records", str(records_path), "--replace", "--keep-bindings"]
        )
        == 0
    )
    assert expand.run([str(project_path)]) == 0
    project = load_project(project_path)
    assert len(project.report_slides) == 2
    by_id = {asset.id: Path(asset.path).name for asset in project.assets}

    def names(ordinal: int) -> list[str]:
        slide = project.report_slides[ordinal].slide
        found = []
        for frame_id in ("frame-1", "frame-2"):
            binding = next(item for item in slide.bindings if item.element_id == frame_id)
            found.append(by_id[binding.asset_id])
        return found

    assert names(0) == ["img_1.png", "img_2.png"]
    assert names(1) == ["img_3.png", "img_4.png"]


def test_full_flow_from_scratch_produces_four_slides_and_pptx(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)

    # 1枚目の型を「画像2枚 横並び」に差し替え
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0

    # 素材を 4 枚登録 (pattern が 2 枚なので 2 スライドに展開される)
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 5)]
    records_path = _write_records(tmp_path / "records.json", images)
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0

    # タイトルと見解テンプレートを保存
    assert (
        pick_templates.run(
            [
                str(project_path),
                "--title",
                "検査結果",
                "--caption",
                "見解テンプレート",
            ]
        )
        == 0
    )

    # 2 スライドに展開
    assert expand.run([str(project_path), "--overwrite-labels"]) == 0
    project = load_project(project_path)
    assert len(project.report_slides) == 2

    # 1 枚目のタイトルと見解を書き換え
    slide_id = project.report_slides[0].slide.id
    assert (
        update_slide.run(
            [
                str(project_path),
                "--slide",
                slide_id,
                "--title",
                "1 枚目の確認",
                "--caption",
                "差し替えた見解",
            ]
        )
        == 0
    )
    project = load_project(project_path)
    first_slide = project.report_slides[0].slide
    assert first_slide.title == "1 枚目の確認"
    caption_node = next(
        node
        for node in _walk(project.content_master.root)
        if isinstance(node, TextNode) and node.role_id == "caption"
    )
    caption_binding = next(
        binding
        for binding in first_slide.bindings
        if binding.element_id == caption_node.id
    )
    assert caption_binding.text == "差し替えた見解"

    # PPTX に書き出し
    destination = tmp_path / "out" / "report.pptx"
    assert export_pptx.run([str(project_path), "--out", str(destination)]) == 0
    assert destination.exists()
    presentation = Presentation(destination)
    assert len(presentation.slides) == 2


def test_title_template_appears_on_the_slide_preview(tmp_path: Path):
    project = create_report(paper="landscape")
    project_path = tmp_path / "project.json"
    save_project(project, project_path)

    assert pick_templates.run([str(project_path), "--title", "キズ検査", "--caption", "説明"]) == 0

    loaded = load_project(project_path)
    assert loaded.slide.title == "キズ検査"
    placed = layout_slide(loaded)
    assert placed.title_text == "キズ検査"
    assert placed.title_frame is not None


def test_expand_keeps_headings_on_the_first_slide(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0
    images = [_png(tmp_path / f"img_{i}.png") for i in range(1, 5)]
    records_path = _write_records(tmp_path / "records.json", images)
    assert add_source.run([str(project_path), "--records", str(records_path)]) == 0
    project = load_project(project_path)
    assert update_slide.run([str(project_path), "--bind", "frame-1", project.assets[0].id]) == 0
    assert update_slide.run([str(project_path), "--heading", "frame-1", "全体"]) == 0
    assert update_slide.run([str(project_path), "--heading-place", "frame-1", "below"]) == 0
    assert expand.run([str(project_path)]) == 0

    project = load_project(project_path)
    assert len(project.report_slides) == 2
    for report in project.report_slides:
        binding = next(item for item in report.slide.bindings if item.element_id == "frame-1")
        assert binding.text == "全体"
        assert binding.text_anchor == "below"

    assert update_slide.run([str(project_path), "--slide", "slide-2", "--heading", "frame-1", "別見出し"]) == 0
    assert expand.run([str(project_path)]) == 0
    project = load_project(project_path)
    first = next(item for item in project.report_slides[0].slide.bindings if item.element_id == "frame-1")
    second = next(item for item in project.report_slides[1].slide.bindings if item.element_id == "frame-1")
    assert first.text == "全体"
    assert second.text == "別見出し"


def test_added_text_can_be_resized_and_deleted(tmp_path: Path):
    project_path = _save_initial_project(tmp_path)
    assert pick_layout.run([str(project_path), "--preset", "horizontal-2"]) == 0
    assert update_slide.run([str(project_path), "--add-text", "--text", "メモ"]) == 0
    project = load_project(project_path)
    note = next(node for node in _walk(project.content_master.root) if isinstance(node, TextNode) and node.role_id == "note")
    before = note.free_rect.width
    assert update_slide.run([str(project_path), "--text-box", note.id, "40", "50", "400", "80"]) == 0
    project = load_project(project_path)
    note = next(node for node in _walk(project.content_master.root) if isinstance(node, TextNode) and node.id == note.id)
    assert note.free_rect is not None
    assert note.free_rect.width > before
    assert update_slide.run([str(project_path), "--remove-text", note.id]) == 0
    project = load_project(project_path)
    assert all(not (isinstance(node, TextNode) and node.id == note.id) for node in _walk(project.content_master.root))


def _walk(node):
    yield node
    for child in getattr(node, "children", []) or []:
        yield from _walk(child)
