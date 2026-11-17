from pathlib import Path

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
