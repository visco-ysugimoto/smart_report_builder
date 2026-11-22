"""画像ソースを素材として登録する。

Flutter 側が VTV・フォルダ・タスクファイルを展開した結果の JSON を受け取り、
Project.assets へ並びの番号付きで追加する。既存の素材は更新だけ行う。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from smart_report_builder import roi_edit
from smart_report_builder.ordered_assignment import register_ordered_assets


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="register-source",
        description="Register image assets to a project with sequential list indices",
    )
    parser.add_argument("project")
    parser.add_argument("--records", required=True, help="JSON file containing list of asset records")
    parser.add_argument("--list-name", default="")
    parser.add_argument("--list-comment", default="")
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    parser.add_argument("--replace", action="store_true", help="Clear existing assets before adding")
    parser.add_argument(
        "--keep-bindings",
        action="store_true",
        help="Replace the asset list but keep bindings for images that remain",
    )
    args = parser.parse_args(argv)
    try:
        raw = Path(args.records).read_text(encoding="utf-8")
        payload = json.loads(raw)
        if not isinstance(payload, list):
            raise ValueError("records must be a list")
        project = roi_edit.load_project(args.project)
        if args.replace and not args.keep_bindings:
            project.assets.clear()
            for slide in _slides(project):
                slide.bindings = [item for item in slide.bindings if item.text is not None]
        records = _normalize_records(
            payload, list_name=args.list_name, list_comment=args.list_comment
        )
        added, updated, ids = register_ordered_assets(project, records)
        if args.keep_bindings:
            _retain_recorded_order(project, ids)
        roi_edit._save_outputs(project, args.project, args.layout, args.pptx, record_undo=False)
    except (ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"added {added} updated {updated}")
    for asset_id in ids:
        print(f"asset {asset_id}")
    return 0


def _normalize_records(records: list, *, list_name: str, list_comment: str) -> list[dict]:
    normalized: list[dict] = []
    for index, raw in enumerate(records, start=1):
        if not isinstance(raw, dict):
            raise ValueError("record must be an object")
        path = raw.get("path")
        if not path:
            raise ValueError("record missing path")
        source = raw.get("source") or "folder"
        record = {
            "path": str(path),
            "source": str(source),
            "listIndex": int(raw.get("listIndex", index)),
            "listName": raw.get("listName") or list_name,
            "listComment": raw.get("listComment") or list_comment,
            "group": raw.get("group") or "",
            "task": raw.get("task") or "",
            "fileName": raw.get("fileName") or Path(str(path)).name,
            "note": raw.get("note") or "",
        }
        normalized.append(record)
    return normalized


def _retain_recorded_order(project, ids: list[str]) -> None:
    """今回の並びだけを残し、同じファイルの素材 ID と枠への割当は維持する。"""
    by_id = {asset.id: asset for asset in project.assets}
    project.assets = [by_id[asset_id] for asset_id in ids if asset_id in by_id]
    kept = {asset.id for asset in project.assets}
    for slide in _slides(project):
        slide.bindings = [
            item for item in slide.bindings if item.asset_id is None or item.asset_id in kept
        ]


def _slides(project):
    if project.report_slides:
        return [item.slide for item in project.report_slides]
    return [project.slide]
