"""任意のパスへ PPTX を書き出す。元のテンプレートを残したまま N スライド分出力する。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from smart_report_builder import roi_edit
from smart_report_builder.layout import layout_slide
from smart_report_builder.pptx_writer import write_pptx_slides
from smart_report_builder.roi_edit import layouts_for_pptx


def run(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="save-pptx",
        description="Write the current project to a PPTX file",
    )
    parser.add_argument("project")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        project = roi_edit.load_project(args.project)
        result = layout_slide(project)
        destination = Path(args.out)
        destination.parent.mkdir(parents=True, exist_ok=True)
        prior = destination if destination.is_file() else None
        write_pptx_slides(
            layouts_for_pptx(project, result),
            destination,
            prior_path=prior,
        )
    except (ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"saved {args.out}")
    return 0
