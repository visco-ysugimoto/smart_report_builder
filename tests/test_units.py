from pptx.util import Pt

from smart_report_builder.units import EMU_PER_PT, emu_to_pt, pt_to_emu


def test_point_to_emu_matches_powerpoint_units():
    assert EMU_PER_PT == 12700
    assert pt_to_emu(1) == 12700
    assert pt_to_emu(72) == 914400
    assert pt_to_emu(0.5) == 6350
    assert pt_to_emu(960) == int(Pt(960))
    assert pt_to_emu(540) == int(Pt(540))
    assert pt_to_emu(106.5) == int(Pt(106.5))
    assert emu_to_pt(12700) == 1
    assert emu_to_pt(914400) == 72
