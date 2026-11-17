"""プロジェクト JSON の保存と再読込。

素材はパス参照だけを保存し、画像本体はコピーも変更もしない。
同じドライブ上のパスはプロジェクトファイルからの相対パスにする。
配置結果は派生データで、再読込後に layout_slide で計算し直す。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from smart_report_builder.models import (
    LayoutResult,
    Project,
    layout_result_from_dict,
    layout_result_to_dict,
    project_from_dict,
    project_to_dict,
)


def save_project(project: Project, path: str | Path) -> None:
    destination = Path(path)
    payload = project_to_dict(project)
    project_dir = destination.parent
    for stored, asset in zip(payload["assets"], project.assets, strict=True):
        stored["path"] = _to_stored_path(asset.path, project_dir)
    _write_json(destination, payload)


def load_project(path: str | Path) -> Project:
    source = Path(path)
    payload = _read_json_object(source)
    project_dir = source.parent
    assets = payload.get("assets")
    if isinstance(assets, list):
        for asset in assets:
            if isinstance(asset, dict) and "path" in asset and asset["path"] is not None:
                asset["path"] = _from_stored_path(str(asset["path"]), project_dir)
    return project_from_dict(payload)


def missing_asset_paths(project: Project) -> list[str]:
    missing: list[str] = []
    for asset in project.assets:
        if not Path(asset.path).is_file():
            missing.append(asset.path)
    return missing


def save_layout_result(result: LayoutResult, path: str | Path) -> None:
    _write_json(Path(path), layout_result_to_dict(result))


def load_layout_result(path: str | Path) -> LayoutResult:
    return layout_result_from_dict(_read_json_object(Path(path)))


def _to_stored_path(asset_path: str, project_dir: Path) -> str:
    source = Path(asset_path)
    if not source.is_absolute():
        return source.as_posix()
    try:
        relative = os.path.relpath(source.resolve(), project_dir.resolve())
    except (OSError, ValueError):
        return str(source)
    return Path(relative).as_posix()


def _from_stored_path(stored: str, project_dir: Path) -> str:
    path = Path(stored)
    if path.is_absolute():
        return str(path)
    return str((project_dir / path).resolve())


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f"{path.name}.tmp"
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    temporary.write_text(text, encoding="utf-8")
    try:
        os.replace(temporary, path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _read_json_object(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        raise
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON として読めない: {path.name}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"JSON オブジェクトではない: {path.name}")
    return payload
