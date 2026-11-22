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
)
from smart_report_builder.layout import layout_slide
from smart_report_builder.models import (
    Asset,
    Binding,
    FitMode,
    GridNode,
    ImageFrameNode,
    Inheritance,
    Roi,
    TextNode,
    project_from_dict,
    project_to_dict,
)
from smart_report_builder.practical import (
    add_measurement_table,
    apply_assignment_candidate,
    apply_master_roi,
    apply_ready_candidates,
    apply_variant,
    assignment_candidates,
    capture_master_roi,
    propose_variants,
    set_table_cell,
    update_master_roi,
    add_dataset_asset,
    add_image_frame,
    add_table_column,
    add_table_row,
    create_dataset,
    remove_dataset_asset,
    remove_image_frame,
    set_image_frame_kind,
)
from smart_report_builder.project_factory import create_report
from smart_report_builder.project_store import load_project, save_project
from smart_report_builder.pptx_writer import write_pptx
from smart_report_builder.roi_edit import (
    apply_normalized_roi,
    arrange_roi_zooms,
    main,
    remove_unused_asset,
)


def test_assignment_candidates_wait_for_a_choice(tmp_path: Path):
    overall = _png(tmp_path / "overall.png", (800, 400))
    project = build_two_image_project(overall, tmp_path / "comparison.png")
    project.slide.bindings = []
    ready = [item for item in assignment_candidates(project) if item.status == "ready"]
    assert [(item.element_id, item.asset_id) for item in ready] == [(FRAME_OVERALL_ID, "asset-overall"), (FRAME_COMPARE_ID, "asset-compare")]
    assert {item.confidence for item in ready} == {1.0}
    assert {item.label for item in ready} == {"確定候補"}
    before = [item.asset_id for item in project.slide.bindings]
    assert before == []
    apply_assignment_candidate(project, FRAME_OVERALL_ID, "asset-overall")
    assert project.slide.bindings == [Binding(element_id=FRAME_OVERALL_ID, asset_id="asset-overall")]
    with pytest.raises(ValueError, match="候補にありません"):
        apply_assignment_candidate(project, FRAME_COMPARE_ID, "missing-asset")


def test_partial_names_stay_unconfirmed():
    project = build_two_image_project()
    project.slide.bindings = []
    project.assets[0].display_name = "全体画像"
    project.assets.append(
        Asset(id="asset-extra", path="overall-copy.png", width_px=10, height_px=10, display_name="全体画像")
    )
    conflicts = [
        item
        for item in assignment_candidates(project)
        if item.element_id == FRAME_OVERALL_ID and item.status == "conflict"
    ]
    assert {item.asset_id for item in conflicts} == {"asset-overall", "asset-extra"}
    assert {item.label for item in conflicts} == {"競合"}
    assert project.slide.bindings == []


def test_role_keywords_and_folder_order_wait_for_acceptance(tmp_path: Path):
    project = create_report(image_count=2)
    project.assets = [
        _asset(tmp_path / "lot" / "全体_01.png", "asset-overall", (80, 40)),
        _asset(tmp_path / "lot" / "比較-02.png", "asset-compare", (40, 80)),
        _asset(tmp_path / "lot" / "plain-b.png", "asset-b", (20, 20)),
        _asset(tmp_path / "lot" / "plain-a.png", "asset-a", (20, 20)),
    ]
    before = project_to_dict(project)
    found = assignment_candidates(project)
    assert project_to_dict(project) == before
    weak = {(item.element_id, item.asset_id, item.confidence, item.reason) for item in found if item.status == "confirm"}
    assert weak == {
        ("frame-overall", "asset-overall", 0.4, "ファイル名の役割語が一致"),
        ("frame-compare", "asset-compare", 0.4, "ファイル名の役割語が一致"),
    }
    assert all(item.label == "確認推奨" for item in found if item.status == "confirm")
    assert [item for item in found if item.status == "ready"] == []

    project.assets = [
        _asset(tmp_path / "only" / "plain-b.png", "asset-b", (20, 20)),
        _asset(tmp_path / "only" / "plain-a.png", "asset-a", (20, 20)),
    ]
    ordered = [item for item in assignment_candidates(project) if item.status == "confirm"]
    assert [(item.element_id, item.asset_id, item.label, item.reason) for item in ordered] == [
        ("frame-overall", "asset-a", "確認推奨", "同じフォルダのファイル名順"),
        ("frame-compare", "asset-b", "確認推奨", "同じフォルダのファイル名順"),
    ]
    assert all(item.confidence == 0.5 for item in ordered)
    assert apply_ready_candidates(project) == []
    assert project.slide.bindings == []
    apply_assignment_candidate(project, "frame-compare", "asset-b")
    assert project.slide.bindings == [Binding(element_id="frame-compare", asset_id="asset-b")]
    assert all(item.element_id != "frame-overall" or item.asset_id != "asset-b" for item in assignment_candidates(project))


def test_ambiguous_keywords_are_conflicts_and_do_not_overwrite(tmp_path: Path):
    project = create_report(image_count=2)
    project.assets = [
        _asset(tmp_path / "全体_a.png", "asset-a", (10, 10)),
        _asset(tmp_path / "全体_b.png", "asset-b", (10, 10)),
        _asset(tmp_path / "全体_比較.png", "asset-both", (10, 10)),
        _asset(tmp_path / "zooming.png", "asset-zoomish", (10, 10)),
        _asset(tmp_path / "処理後_1.png", "asset-processed", (10, 10)),
    ]
    conflicts = [
        (item.element_id, item.asset_id)
        for item in assignment_candidates(project)
        if item.status == "conflict" and item.label == "競合"
    ]
    assert ("frame-overall", "asset-a") in conflicts
    assert ("frame-overall", "asset-b") in conflicts
    assert ("frame-overall", "asset-both") in conflicts
    assert ("frame-compare", "asset-both") in conflicts
    assert all(item.asset_id != "asset-zoomish" for item in assignment_candidates(project))
    assert all(item.asset_id != "asset-processed" for item in assignment_candidates(project))
    assert apply_ready_candidates(project) == []
    assert project.slide.bindings == []
    apply_assignment_candidate(project, "frame-compare", "asset-both")
    assert [(item.element_id, item.asset_id) for item in project.slide.bindings] == [
        ("frame-compare", "asset-both")
    ]
    project.slide.bindings = []
    with pytest.raises(ValueError, match="候補にありません"):
        apply_assignment_candidate(project, "frame-overall", "missing")

    project.slide.bindings = [Binding(element_id="frame-overall", asset_id="asset-kept")]
    project.assets.append(_asset(tmp_path / "kept.png", "asset-kept", (8, 8)))
    kept = project_to_dict(project)
    assert all(item.element_id != "frame-overall" for item in assignment_candidates(project))
    with pytest.raises(ValueError, match="上書きしません"):
        apply_assignment_candidate(project, "frame-overall", "asset-a")
    assert project_to_dict(project) == kept


def test_custom_synonyms_and_zoom_role_need_a_contain_frame(tmp_path: Path):
    project = create_report(template="overall-zoom")
    project.assets = [
        _asset(tmp_path / "外観01.png", "asset-look", (30, 20)),
        _asset(tmp_path / "拡大_9.png", "asset-zoom", (12, 12)),
    ]
    untouched = assignment_candidates(project)
    assert [(item.asset_id, item.status, item.label) for item in untouched] == [
        ("asset-look", "confirm", "確認推奨")
    ]
    assert all(item.element_id != "frame-zoom" for item in untouched)
    custom = {"overall": ["外観"]}
    found = assignment_candidates(project, custom)
    assert [(item.element_id, item.asset_id, item.status) for item in found] == [
        ("frame-overall", "asset-look", "confirm")
    ]
    processed_project = create_report(template="overall-zoom")
    images = processed_project.content_master.root.children[0]
    images.children.append(
        ImageFrameNode(id="frame-processed", role_id="processed", display_name="処理", fit_mode=FitMode.CONTAIN)
    )
    processed_project.assets = [_asset(tmp_path / "pics" / "処理_3.png", "asset-proc", (16, 16))]
    processed = [item for item in assignment_candidates(processed_project) if item.element_id == "frame-processed"]
    assert [(item.asset_id, item.status, item.confidence) for item in processed] == [("asset-proc", "confirm", 0.4)]
    assert all(item.element_id != "frame-zoom" for item in assignment_candidates(processed_project))
    assert project.slide.bindings == []


def test_suggest_and_accept_ready_commands_leave_conflicts(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    project = create_report()
    project.assets = [
        _asset(tmp_path / "batch" / "全体.png", "asset-overall", (24, 16)),
        _asset(tmp_path / "batch" / "note.png", "asset-note", (24, 16)),
        _asset(tmp_path / "other" / "extra.png", "asset-extra", (16, 24)),
    ]
    path = tmp_path / "project.json"
    save_project(project, path)
    before = path.read_bytes()
    synonyms = tmp_path / "synonyms.json"
    synonyms.write_text('{"overall": ["全体"], "comparison": ["比較"]}\n', encoding="utf-8")
    assert main(["suggest", str(path), "--synonyms", str(synonyms)]) == 0
    assert path.read_bytes() == before
    lines = [line for line in capsys.readouterr().out.splitlines() if line and line != "none"]
    assert any(line.startswith("confirm\tframe-overall\tasset-overall\t") and "\t0.40\t確認推奨\t" in line for line in lines)
    assert any(line.startswith("conflict\t") and line.endswith("フォルダが複数あるため、並びを自動では選べない") for line in lines)

    assert main(["accept-ready", str(path), "--synonyms", str(synonyms)]) == 0
    saved = load_project(path)
    assert saved.slide.bindings == []
    output = capsys.readouterr().out
    assert output.strip() == "none"


def test_broken_synonym_file_does_not_change_the_project(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    project = create_report()
    path = tmp_path / "project.json"
    save_project(project, path)
    before = path.read_bytes()
    broken = tmp_path / "synonyms.json"
    broken.write_text("{", encoding="utf-8")
    assert main(["suggest", str(path), "--synonyms", str(broken)]) == 1
    assert "同義語ファイルを読めない" in capsys.readouterr().err
    assert path.read_bytes() == before
    missing = tmp_path / "missing.json"
    assert main(["accept-ready", str(path), "--synonyms", str(missing)]) == 1
    assert path.read_bytes() == before


def test_session_lists_candidates_without_writing_and_accepts_on_save(tmp_path: Path):
    from smart_report_builder.edit_session import EditSession

    project = create_report()
    project.assets = [_asset(tmp_path / "pics" / "比較.png", "asset-compare", (12, 20))]
    project_path, layout_path, pptx_path = tmp_path / "layout.project.json", tmp_path / "layout.layout.json", tmp_path / "layout.pptx"
    save_project(project, project_path)
    before = project_path.read_bytes()
    session = EditSession()
    session.open(str(project_path), str(layout_path), str(pptx_path))
    listed = session.run(["suggest", str(project_path)])
    assert listed["code"] == 0
    assert listed["dirty"] is False
    assert "confirm\tframe-compare\tasset-compare\t" in listed["stdout"]
    assert "0.40\t確認推奨\tファイル名の役割語が一致" in listed["stdout"]
    assert project_path.read_bytes() == before
    assert not layout_path.exists()

    skipped = session.run(["accept-ready", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)])
    assert skipped["code"] == 0
    assert skipped["dirty"] is False
    assert skipped["stdout"].strip() == "none"
    accepted = session.run(
        [
            "apply-suggestion",
            str(project_path),
            "frame-compare",
            "asset-compare",
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )
    assert accepted["code"] == 0
    assert accepted["dirty"] is True
    assert project_path.read_bytes() == before
    assert not pptx_path.exists()
    assert accepted["project"]["slide"]["bindings"] == [
        {"elementId": "frame-compare", "assetId": "asset-compare", "text": None}
    ]
    saved = session.save()
    assert saved["code"] == 0
    assert load_project(project_path).slide.bindings[0].asset_id == "asset-compare"


def test_overflow_offers_at_most_three_variants_until_one_is_chosen():
    project = create_report(image_count=2, arrangement="vertical")
    project.assets = [
        Asset(id="asset-a", path="a.png", width_px=800, height_px=400, display_name="広い"),
        Asset(id="asset-b", path="b.png", width_px=400, height_px=800, display_name="高い"),
    ]
    project.slide.bindings = [
        Binding(element_id="frame-overall", asset_id="asset-a"),
        Binding(element_id="frame-compare", asset_id="asset-b"),
    ]
    caption = project.content_master.root.children[1]
    assert isinstance(caption, TextNode)
    caption.height_pt = 400
    proposals = propose_variants(project)
    assert proposals[0].variant_id == "standard"
    assert proposals[0].selected is True
    assert 1 < len(proposals) <= 3
    assert project.content_master.root.children[0].direction.value == "vertical"
    apply_variant(project, "equal")
    assert project.content_master.root.children[0].track_aspect is False
    heights = [item.frame.height for item in layout_slide(project).elements[:2]]
    assert heights[0] == pytest.approx(heights[1])


def test_master_roi_inheritance_and_batch_keep_corrections(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    project = build_roi_project(image, (800, 400))
    master_id = capture_master_roi(project, ROI_ID)
    update_master_roi(project, master_id, 0.3, 0.2, 0.2, 0.6)
    inherited = layout_slide(project)
    roi = next(item for item in inherited.elements if item.element_id == ROI_ID)
    stored = project.slide.rois[0]
    assert stored.x == pytest.approx(0.1)
    assert stored.inheritance == Inheritance.INHERIT
    assert roi.crop.x == pytest.approx(0.3)

    apply_normalized_roi(project, ROI_ID, 0.4, 0.2, 0.2, 0.6)
    assert stored.inheritance == Inheritance.RELATIVE
    assert stored.dx == pytest.approx(0.1)
    update_master_roi(project, master_id, 0.2, 0.2, 0.2, 0.6)
    moved = layout_slide(project)
    placed = next(item for item in moved.elements if item.element_id == ROI_ID)
    assert placed.crop.x == pytest.approx(0.3)

    two = build_two_image_project(image, tmp_path / "comparison.png")
    two.slide.rois = project.slide.rois
    two.content_master.master_rois = project.content_master.master_rois
    applied, skipped = apply_master_roi(two, master_id, [FRAME_OVERALL_ID, FRAME_COMPARE_ID])
    assert applied == 1
    assert skipped == 1
    copied = next(item for item in two.slide.rois if item.source_element_id == FRAME_COMPARE_ID)
    assert copied.inheritance == Inheritance.INHERIT
    copied.inheritance = Inheritance.DETACHED
    again, protected = apply_master_roi(two, master_id, [FRAME_COMPARE_ID])
    assert (again, protected) == (0, 1)
    assert copied.inheritance == Inheritance.DETACHED


def test_table_keeps_cell_text_and_exports_a_native_table(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    _png(tmp_path / "comparison.png", (400, 800))
    project = build_two_image_project(image, tmp_path / "comparison.png")
    table_id = add_measurement_table(project)
    long_text = "測定値は短縮してはいけません。"
    set_table_cell(project, table_id, 1, 1, long_text)
    set_table_cell(project, table_id, 0, 0, "  項目全文  ")
    result = layout_slide(project)
    table = next(item for item in result.elements if item.element_id == table_id)
    assert table.kind == "table"
    assert table.table_rows[1][1] == long_text
    assert table.table_rows[0][0] == "  項目全文  "
    caption = next(item for item in result.elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    destination = tmp_path / "report.pptx"
    write_pptx(result, destination)
    shapes = list(Presentation(destination).slides[0].shapes)
    tables = [shape for shape in shapes if shape.shape_type == MSO_SHAPE_TYPE.TABLE]
    assert len(tables) == 1
    assert tables[0].table.cell(1, 1).text == long_text
    assert tables[0].table.cell(0, 0).text == "  項目全文  "


def test_add_table_row_keeps_existing_cells(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    _png(tmp_path / "comparison.png", (400, 800))
    project = build_two_image_project(image, tmp_path / "comparison.png")
    table_id = add_measurement_table(project)
    long_text = "測定値は短縮してはいけません。"
    set_table_cell(project, table_id, 1, 1, long_text)
    before = layout_slide(project)
    before_table = next(item for item in before.elements if item.element_id == table_id)
    row_index = add_table_row(project, table_id)
    assert row_index == 2
    result = layout_slide(project)
    table = next(item for item in result.elements if item.element_id == table_id)
    assert table.table_rows == [["項目", "値"], ["結果", long_text], ["", ""]]
    assert table.frame.height == pytest.approx(before_table.frame.height + 36)
    caption = next(item for item in result.elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    images = [item for item in result.elements if item.kind == "image_frame"]
    assert len(images) == len([item for item in before.elements if item.kind == "image_frame"])
    with pytest.raises(ValueError, match="表が見つからない"):
        add_table_row(project, "missing-table")
    destination = tmp_path / "report.pptx"
    write_pptx(result, destination)
    exported = next(shape for shape in Presentation(destination).slides[0].shapes if shape.shape_type == MSO_SHAPE_TYPE.TABLE)
    assert exported.table.cell(1, 1).text == long_text
    assert exported.table.cell(2, 0).text == ""
    assert exported.table.cell(2, 1).text == ""


def test_add_table_column_keeps_existing_cells_and_the_frame(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    _png(tmp_path / "comparison.png", (400, 800))
    project = build_two_image_project(image, tmp_path / "comparison.png")
    table_id = add_measurement_table(project)
    long_text = "測定値は短縮してはいけません。"
    set_table_cell(project, table_id, 1, 1, long_text)
    before = layout_slide(project)
    before_table = next(item for item in before.elements if item.element_id == table_id)
    column_index = add_table_column(project, table_id)
    assert column_index == 2
    result = layout_slide(project)
    table = next(item for item in result.elements if item.element_id == table_id)
    assert table.table_rows == [["項目", "値", ""], ["結果", long_text, ""]]
    assert table.frame == before_table.frame
    caption = next(item for item in result.elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    with pytest.raises(ValueError, match="表が見つからない"):
        add_table_column(project, "missing-table")
    destination = tmp_path / "report.pptx"
    write_pptx(result, destination)
    exported = next(shape for shape in Presentation(destination).slides[0].shapes if shape.shape_type == MSO_SHAPE_TYPE.TABLE)
    assert exported.table.cell(1, 1).text == long_text
    assert exported.table.cell(0, 2).text == ""
    assert exported.table.cell(1, 2).text == ""


def test_add_image_frame_keeps_the_caption_and_existing_assets(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    _png(tmp_path / "comparison.png", (400, 800))
    project = build_two_image_project(image, tmp_path / "comparison.png")
    before = layout_slide(project)
    before_caption = next(item for item in before.elements if item.kind == "text")
    bindings = list(project.slide.bindings)
    assets = [(item.id, item.path) for item in project.assets]
    assert add_image_frame(project) == "frame-1"
    assert add_image_frame(project) == "frame-2"
    result = layout_slide(project)
    added = next(item for item in result.elements if item.element_id == "frame-1")
    assert added.display_name == "画像1"
    assert added.role_id == "image"
    assert added.fit_mode == "contain"
    assert added.asset_path is None
    caption = next(item for item in result.elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    assert caption.frame == before_caption.frame
    assert [(item.id, item.path) for item in project.assets] == assets
    assert project.slide.bindings == bindings
    assert {item.element_id for item in result.elements if item.kind == "image_frame"} == {
        "frame-overall",
        "frame-compare",
        "frame-1",
        "frame-2",
    }
    destination = tmp_path / "report.pptx"
    write_pptx(result, destination)
    pictures = [shape for shape in Presentation(destination).slides[0].shapes if shape.shape_type == MSO_SHAPE_TYPE.PICTURE]
    assert len(pictures) == 2
    grid = create_report(image_count=2, arrangement="grid")
    add_image_frame(grid)
    container = grid.content_master.root.children[0]
    assert isinstance(container, GridNode)
    assert container.columns == 2
    bare = create_report()
    bare.content_master.root = TextNode(
        id="text-caption",
        role_id="caption",
        display_name="説明",
        text=DEFAULT_CAPTION,
    )
    with pytest.raises(ValueError, match="画像枠を追加できません"):
        add_image_frame(bare)


def test_remove_contain_frame_keeps_the_file_zoom_frame_and_caption(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    project = build_roi_project(image)
    before = layout_slide(project)
    before_caption = next(item for item in before.elements if item.kind == "text")
    remove_image_frame(project, FRAME_OVERALL_ID)
    result = layout_slide(project)
    ids = {item.element_id for item in result.elements}
    assert FRAME_OVERALL_ID not in ids
    assert ZOOM_FRAME_ID in ids
    assert project.slide.rois == []
    assert any(asset.id == "asset-overall" for asset in project.assets)
    assert image.exists()
    caption = next(item for item in result.elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    assert caption.frame == before_caption.frame
    remove_image_frame(project, ZOOM_FRAME_ID)
    assert all(item.element_id != ZOOM_FRAME_ID for item in layout_slide(project).elements)
    assert image.exists()
    two = build_two_image_project(image, tmp_path / "comparison.png")
    _png(tmp_path / "comparison.png", (400, 800))
    remove_image_frame(two, FRAME_OVERALL_ID)
    remove_image_frame(two, FRAME_COMPARE_ID)
    assert add_image_frame(two) == "frame-1"
    assert any(asset.id == "asset-compare" for asset in two.assets)


def test_remove_zoom_frame_keeps_the_roi_rectangle_and_the_file(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    project = build_roi_project(image)
    project.slide.rois.append(
        Roi(
            id="roi-2",
            name="ROI 2",
            source_element_id=FRAME_OVERALL_ID,
            x=0.5,
            y=0.1,
            width=0.2,
            height=0.3,
        )
    )
    arrange_roi_zooms(project, "horizontal")
    rectangles = [(roi.x, roi.y, roi.width, roi.height) for roi in project.slide.rois]
    first, second = (roi.zoom_element_id for roi in project.slide.rois)

    remove_image_frame(project, first)
    assert [(roi.x, roi.y, roi.width, roi.height) for roi in project.slide.rois] == rectangles
    assert project.slide.rois[0].zoom_element_id is None
    assert project.slide.rois[1].zoom_element_id == second
    assert image.exists()
    assert any(asset.id == "asset-overall" for asset in project.assets)
    assert any(item.element_id == FRAME_OVERALL_ID for item in layout_slide(project).elements)
    assert all(item.element_id != first for item in layout_slide(project).elements)

    remove_image_frame(project, second)
    assert [(roi.x, roi.y, roi.width, roi.height) for roi in project.slide.rois] == rectangles
    assert project.slide.rois[1].zoom_element_id is None
    assert all(child.id not in {"stack-zooms", "grid-zooms"} for child in project.content_master.root.children)


def test_dataset_groups_assets_without_assigning_or_deleting_files(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    extra = _png(tmp_path / "extra.png", (32, 16))
    project = build_two_image_project(image, tmp_path / "comparison.png")
    _png(tmp_path / "comparison.png", (400, 800))
    project.assets.append(
        Asset(id="asset-1", path=str(extra), width_px=32, height_px=16, display_name="extra")
    )
    assert "datasets" not in project_to_dict(project)
    bindings = list(project.slide.bindings)
    dataset_id = create_dataset(project, "  対象Aの全文  ", ["asset-overall", "asset-overall", "asset-1"])
    assert dataset_id == "dataset-1"
    assert project.datasets[0].name == "対象Aの全文"
    assert project.datasets[0].asset_ids == ["asset-overall", "asset-1"]
    assert project.slide.bindings == bindings
    restored = project_from_dict(project_to_dict(project))
    assert restored.datasets[0].asset_ids == ["asset-overall", "asset-1"]
    with pytest.raises(ValueError, match="すでにそのグループに入っています"):
        add_dataset_asset(project, dataset_id, "asset-1")
    add_dataset_asset(project, dataset_id, "asset-compare")
    remove_dataset_asset(project, dataset_id, "asset-compare")
    assert project.datasets[0].asset_ids == ["asset-overall", "asset-1"]
    remove_unused_asset(project, "asset-1")
    assert project.datasets[0].asset_ids == ["asset-overall"]
    assert extra.exists()
    assert any(asset.id == "asset-overall" for asset in project.assets)
    caption = next(item for item in layout_slide(project).elements if item.kind == "text")
    assert caption.text == DEFAULT_CAPTION
    with pytest.raises(ValueError, match="グループ名が空です"):
        create_dataset(project, "   ", ["asset-overall"])
    with pytest.raises(ValueError, match="素材が見つからない"):
        create_dataset(project, "予備", ["missing-asset"])


def test_history_undoes_and_redoes_more_than_one_edit(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    project_path = tmp_path / "sample_roi.project.json"
    save_project(build_roi_project(image, (800, 400)), project_path)
    assert main([str(project_path), ROI_ID, "0.20", "0.20", "0.20", "0.20"]) == 0
    assert main([str(project_path), ROI_ID, "0.30", "0.20", "0.20", "0.20"]) == 0
    assert main([str(project_path), ROI_ID, "0.40", "0.20", "0.20", "0.20"]) == 0
    assert load_project(project_path).slide.rois[0].x == pytest.approx(0.40)
    assert main(["undo", str(project_path)]) == 0
    assert load_project(project_path).slide.rois[0].x == pytest.approx(0.30)
    assert main(["undo", str(project_path)]) == 0
    assert load_project(project_path).slide.rois[0].x == pytest.approx(0.20)
    assert main(["undo", str(project_path)]) == 0
    assert load_project(project_path).slide.rois[0].x == pytest.approx(0.10)
    assert main(["undo", str(project_path)]) == 1
    assert main(["redo", str(project_path)]) == 0
    assert main(["redo", str(project_path)]) == 0
    assert main(["redo", str(project_path)]) == 0
    assert load_project(project_path).slide.rois[0].x == pytest.approx(0.40)
    assert main(["redo", str(project_path)]) == 1


def test_set_image_frame_kind_switches_between_picture_and_zoom(tmp_path: Path):
    image = _png(tmp_path / "overall.png", (800, 400))
    project = build_roi_project(image)
    project.slide.rois.append(
        Roi(
            id="roi-2",
            name="ROI 2",
            source_element_id=FRAME_OVERALL_ID,
            x=0.5,
            y=0.1,
            width=0.2,
            height=0.3,
        )
    )
    bindings = list(project.slide.bindings)
    rectangles = [(roi.x, roi.y, roi.width, roi.height) for roi in project.slide.rois]

    assert set_image_frame_kind(project, FRAME_OVERALL_ID, "zoom") == FRAME_OVERALL_ID
    overall = _frame(project, FRAME_OVERALL_ID)
    assert overall.role_id == "zoom"
    assert overall.fit_mode.value == "roi"
    assert overall.display_name == "拡大画像2"
    assert project.slide.bindings == bindings
    assert project.slide.rois == []
    placed = next(item for item in layout_slide(project).elements if item.element_id == FRAME_OVERALL_ID)
    assert placed.fit_mode == "roi"
    assert placed.asset_path is None
    overall.display_name = "手入力"
    set_image_frame_kind(project, FRAME_OVERALL_ID, "zoom")
    assert overall.display_name == "手入力"

    assert set_image_frame_kind(project, ZOOM_FRAME_ID, "image") == ZOOM_FRAME_ID
    zoom = _frame(project, ZOOM_FRAME_ID)
    assert zoom.role_id == "image"
    assert zoom.fit_mode.value == "contain"
    assert zoom.display_name == "画像"
    assert project.slide.rois == []

    project = build_roi_project(image)
    assert set_image_frame_kind(project, ZOOM_FRAME_ID, "comparison") == ZOOM_FRAME_ID
    changed = _frame(project, ZOOM_FRAME_ID)
    assert changed.role_id == "image"
    assert changed.fit_mode.value == "contain"
    assert changed.display_name == "画像"
    assert [(roi.x, roi.y, roi.width, roi.height) for roi in project.slide.rois] == rectangles[:1]
    assert project.slide.rois[0].zoom_element_id is None
    shown = next(item for item in layout_slide(project).elements if item.element_id == ZOOM_FRAME_ID)
    assert shown.asset_path is None
    with pytest.raises(ValueError, match="種類は"):
        set_image_frame_kind(project, FRAME_OVERALL_ID, "cover")
    with pytest.raises(ValueError, match="画像枠が見つからない"):
        set_image_frame_kind(project, "missing", "image")


def _frame(project, element_id: str) -> ImageFrameNode:
    def walk(node):
        if isinstance(node, ImageFrameNode) and node.id == element_id:
            return node
        for child in getattr(node, "children", []):
            found = walk(child)
            if found is not None:
                return found
        return None

    found = walk(project.content_master.root)
    assert found is not None
    return found


def _png(path: Path, size: tuple[int, int]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, (20, 40, 60)).save(path, format="PNG")
    return path


def _asset(path: Path, asset_id: str, size: tuple[int, int]) -> Asset:
    _png(path, size)
    return Asset(
        id=asset_id,
        path=str(path),
        width_px=size[0],
        height_px=size[1],
        display_name=path.stem,
    )
