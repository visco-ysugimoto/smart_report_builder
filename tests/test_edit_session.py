import json
from pathlib import Path

from PIL import Image

from smart_report_builder.edit_session import EditSession
from smart_report_builder.project_factory import create_report
from smart_report_builder.project_store import load_project, save_project


def _paths(directory: Path) -> tuple[Path, Path, Path]:
    return (
        directory / "layout.project.json",
        directory / "layout.layout.json",
        directory / "layout.pptx",
    )


def test_edits_stay_in_memory_until_save(tmp_path: Path) -> None:
    project_path, layout_path, pptx_path = _paths(tmp_path)
    save_project(create_report(), project_path)
    before = project_path.read_bytes()
    session = EditSession()
    session.open(project_path, layout_path, pptx_path)

    added = session.run(
        [
            "add-slide",
            str(project_path),
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )
    assert added["code"] == 0
    assert added["dirty"] is True
    assert "slides" in added["project"]
    assert project_path.read_bytes() == before
    assert not layout_path.exists()
    assert not pptx_path.exists()

    kept = session.run(
        [
            "add-slide",
            str(project_path),
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )
    assert kept["code"] == 0
    assert len(kept["project"]["slides"]) == 3
    assert project_path.read_bytes() == before

    undone = session.run(["undo", str(project_path), "--layout", str(layout_path), "--pptx", str(pptx_path)])
    assert undone["code"] == 0
    assert len(undone["project"]["slides"]) == 2
    assert project_path.read_bytes() == before

    failed = session.run(
        [
            "set-frame-kind",
            str(project_path),
            "missing-frame",
            "--kind",
            "zoom",
            "--layout",
            str(layout_path),
            "--pptx",
            str(pptx_path),
        ]
    )
    assert failed["code"] == 1
    assert len(failed["project"]["slides"]) == 2
    assert project_path.read_bytes() == before

    saved = session.save()
    assert saved["code"] == 0
    assert saved["dirty"] is False
    assert project_path.read_bytes() != before
    assert layout_path.is_file()
    assert pptx_path.is_file()
    assert len(load_project(project_path).report_slides) == 2


def test_frame_drop_keeps_unsaved_layout_and_shows_the_image(tmp_path: Path) -> None:
    """トレイからの割当は、保存前のメモリ上のプロジェクトに対して行う。

    ディスクを読み直すと、直前に選んだ枠の並びと登録した素材が消え、
    レイアウトに画像が出ない。
    """
    project_path, layout_path, pptx_path = _paths(tmp_path)
    save_project(create_report(), project_path)
    before = project_path.read_bytes()
    image = tmp_path / "shot.png"
    Image.new("RGB", (32, 24), (20, 40, 60)).save(image)
    records = tmp_path / "records.json"
    records.write_text(
        json.dumps(
            [
                {
                    "path": str(image),
                    "source": "folder",
                    "listIndex": 1,
                    "fileName": image.name,
                }
            ]
        ),
        encoding="utf-8",
    )
    session = EditSession()
    session.open(str(project_path), str(layout_path), str(pptx_path))
    common = ["--layout", str(layout_path), "--pptx", str(pptx_path)]

    laid_out = session.run(["pick-layout", str(project_path), "--preset", "horizontal-4", *common])
    assert laid_out["code"] == 0

    registered = session.run(
        ["register-source", str(project_path), "--records", str(records), *common]
    )
    assert registered["code"] == 0
    assert len(registered["project"]["assets"]) == 1
    asset_id = registered["project"]["assets"][0]["id"]

    bound = session.run(
        ["edit-slide", str(project_path), "--slide", "slide-1", "--bind", "frame-1", asset_id, *common]
    )
    assert bound["code"] == 0, bound["stderr"]
    frames = [item for item in bound["layout"]["elements"] if item["kind"] == "image_frame"]
    assert len(frames) == 4
    placed = next(item for item in frames if item["elementId"] == "frame-1")
    assert placed["assetPath"]
    assert placed["contentRect"] is not None
    assert project_path.read_bytes() == before
