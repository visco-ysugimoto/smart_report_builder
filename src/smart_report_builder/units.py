"""スライドポイントと EMU の変換。

論理座標はスライドポイント。原点はスライド左上。1 inch = 72 pt。
1 pt = 12700 EMU。画面ピクセルと元画像のピクセルは配置座標にしない。
"""

from __future__ import annotations

EMU_PER_PT = 12700
PT_PER_INCH = 72


def pt_to_emu(points: float) -> int:
    return int(round(float(points) * EMU_PER_PT))


def emu_to_pt(emu: int) -> float:
    return float(emu) / EMU_PER_PT
