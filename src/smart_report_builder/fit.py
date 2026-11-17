"""画像枠の中の描画矩形。

既定は contain。縦横比を維持し、枠の外へ出さない。元画像は切らない。
ROI の正規化座標を、表示済み画像の矩形へ写す計算もここに置く。
"""

from __future__ import annotations

from smart_report_builder.models import Rect


def contain_rect(frame: Rect, image_width: float, image_height: float) -> Rect | None:
    if image_width <= 0 or image_height <= 0 or frame.width <= 0 or frame.height <= 0:
        return None
    scale = min(frame.width / image_width, frame.height / image_height)
    width = image_width * scale
    height = image_height * scale
    return Rect(
        x=frame.x + (frame.width - width) / 2,
        y=frame.y + (frame.height - height) / 2,
        width=width,
        height=height,
    )


def map_normalized_rect(target: Rect, normalized: Rect) -> Rect:
    """正規化座標（0〜1）を、表示中の画像矩形の上へ写す。"""
    return Rect(
        x=target.x + (normalized.x * target.width),
        y=target.y + (normalized.y * target.height),
        width=normalized.width * target.width,
        height=normalized.height * target.height,
    )
