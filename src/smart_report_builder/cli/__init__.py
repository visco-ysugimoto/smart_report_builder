"""新 UI 向けの小さなコマンド群。

roi_edit.main() が未知のサブコマンドを受けたとき、このモジュールの dispatch を試す。
各コマンドは既存の計算コア（layout / ordered_assignment / pptx_writer 等）を薄く呼ぶだけで、
ファイルの保存は roi_edit._save_outputs に任せる。
"""

from __future__ import annotations

from typing import Callable

from . import (
    add_source,
    expand,
    export_pptx,
    pick_layout,
    pick_roles,
    pick_templates,
    update_slide,
)

_HANDLERS: dict[str, Callable[[list[str]], int]] = {
    "register-source": add_source.run,
    "pick-layout": pick_layout.run,
    "pick-roles": pick_roles.run,
    "set-templates": pick_templates.run,
    "expand-slides": expand.run,
    "edit-slide": update_slide.run,
    "save-pptx": export_pptx.run,
}


def dispatch(argv: list[str]) -> int | None:
    """未知のコマンドは None を返す。既存の dispatch に任せる。"""
    if not argv:
        return None
    handler = _HANDLERS.get(argv[0])
    if handler is None:
        return None
    return handler(argv[1:])


__all__ = ["dispatch"]
