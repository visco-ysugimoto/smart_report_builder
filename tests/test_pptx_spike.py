from PIL import Image
from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE, MSO_SHAPE_TYPE
from pptx.util import Inches


def test_python_pptx_keeps_text_shape_and_picture_independent(tmp_path):
    image_path = tmp_path / "dot.png"
    Image.new("RGB", (40, 20), (1, 2, 3)).save(image_path, format="PNG")

    presentation = Presentation()
    blank = next(layout for layout in presentation.slide_layouts if layout.name == "Blank")
    slide = presentation.slides.add_slide(blank)
    slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(0.5), Inches(0.5), Inches(2), Inches(1))
    text_box = slide.shapes.add_textbox(Inches(0.5), Inches(2), Inches(4), Inches(0.5))
    text_box.text_frame.text = "独立した文字"
    slide.shapes.add_picture(str(image_path), Inches(3), Inches(0.5), Inches(1), Inches(0.5))

    destination = tmp_path / "spike.pptx"
    presentation.save(destination)

    opened = Presentation(destination)
    shapes = list(opened.slides[0].shapes)
    kinds = {shape.shape_type for shape in shapes}
    assert kinds == {
        MSO_SHAPE_TYPE.AUTO_SHAPE,
        MSO_SHAPE_TYPE.TEXT_BOX,
        MSO_SHAPE_TYPE.PICTURE,
    }
    assert len(shapes) == 3
    assert next(shape for shape in shapes if shape.shape_type == MSO_SHAPE_TYPE.TEXT_BOX).text_frame.text == (
        "独立した文字"
    )
