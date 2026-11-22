"""1 枚目の個別の画像枠の役割を切り替える。

既存の set_image_frame_kind を薄く呼ぶ。変更は content_master に反映される。
"""

from __future__ import annotations

import argparse
import sys

from smart_report_builder import roi_edit
from smart_report_builder.practical import set_image_frame_kind


_ALLOWED = {"image", "zoom"}


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="pick-roles",
        description="Change the role of one image frame on the master slide",
    )
    parser.add_argument("project")
    parser.add_argument("--frame", required=True)
    parser.add_argument("--role", required=True, choices=sorted(_ALLOWED))
    parser.add_argument("--layout")
    parser.add_argument("--pptx")
    args = parser.parse_args(argv)
    try:
        project = roi_edit.load_project(args.project)
        set_image_frame_kind(project, args.frame, args.role)
        roi_edit._save_outputs(project, args.project, args.layout, args.pptx, record_undo=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"role {args.frame} {args.role}")
    return 0
