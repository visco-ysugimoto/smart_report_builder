import pytest

from smart_report_builder.fit import contain_rect, map_normalized_rect
from smart_report_builder.models import Rect


def test_wide_image_is_letterboxed_inside_the_frame():
    frame = Rect(0, 0, 100, 100)
    placed = contain_rect(frame, 200, 100)
    assert placed is not None
    assert placed.x == pytest.approx(0)
    assert placed.y == pytest.approx(25)
    assert placed.width == pytest.approx(100)
    assert placed.height == pytest.approx(50)


def test_tall_image_is_pillarboxed_inside_the_frame():
    frame = Rect(10, 20, 100, 100)
    placed = contain_rect(frame, 100, 200)
    assert placed is not None
    assert placed.x == pytest.approx(35)
    assert placed.y == pytest.approx(20)
    assert placed.width == pytest.approx(50)
    assert placed.height == pytest.approx(100)


def test_square_image_fills_a_square_frame():
    frame = Rect(0, 0, 100, 100)
    placed = contain_rect(frame, 100, 100)
    assert placed == frame


def test_extreme_aspect_stays_inside_the_frame_without_cropping():
    frame = Rect(10, 20, 200, 100)
    placed = contain_rect(frame, 10000, 1)
    assert placed is not None
    assert placed.width == pytest.approx(200)
    assert placed.height == pytest.approx(0.02)
    assert placed.width / placed.height == pytest.approx(10000)
    assert _inside(frame, placed)


def test_normalized_roi_maps_onto_the_rendered_image():
    image = Rect(36, 106.5, 438, 219)
    mapped = map_normalized_rect(image, Rect(0.1, 0.2, 0.2, 0.6))
    assert mapped.x == pytest.approx(79.8)
    assert mapped.y == pytest.approx(150.3)
    assert mapped.width == pytest.approx(87.6)
    assert mapped.height == pytest.approx(131.4)


def test_zero_size_image_or_frame_has_no_rect():
    frame = Rect(0, 0, 100, 100)
    assert contain_rect(frame, 0, 100) is None
    assert contain_rect(frame, 100, 0) is None
    assert contain_rect(Rect(0, 0, 0, 100), 100, 100) is None
    assert contain_rect(Rect(0, 0, 100, -1), 100, 100) is None


def _inside(outer: Rect, inner: Rect) -> bool:
    return (
        inner.x >= outer.x - 1e-9
        and inner.y >= outer.y - 1e-9
        and inner.x + inner.width <= outer.x + outer.width + 1e-9
        and inner.y + inner.height <= outer.y + outer.height + 1e-9
    )
