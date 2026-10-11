r"""Checks the v3 quality helpers without a GPU or model weights:
    gpu_server\.venv\Scripts\python.exe gpu_server\test_enhance.py
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import enhance as E  # noqa: E402

BG = np.array([235, 230, 225])


def parse(a):
    a = a.astype(int)
    seg = np.zeros(a.shape[:2], np.uint8)
    person = np.abs(a - BG).sum(-1) > 40
    seg[person] = 16
    seg[person & (a[..., 0] > 180) & (a[..., 2] < 160)] = E.FACE
    return seg


img = Image.new("RGB", (900, 1600), tuple(BG))
d = ImageDraw.Draw(img)
d.ellipse((400, 300, 500, 420), fill=(200, 160, 130))
d.rectangle((360, 420, 540, 1100), fill=(40, 60, 120))
d.rectangle((380, 1100, 520, 1450), fill=(20, 20, 20))

crop, box = E.crop_to_person(img, parse)
assert box is not None and abs(crop.width / crop.height - E.MODEL_ASPECT) < 0.02, (box, crop.size)

gen = crop.copy()
gen.thumbnail((576, 864))
g = np.asarray(gen).copy()
g[parse(g) == 16] = [150, 30, 30]
out = np.asarray(E.finish_result(img, box, Image.fromarray(g), parse, upscaler=None))
assert out.shape[:2] == (1600, 900)
assert (out[50, 50] == BG).all(), "background must stay original"
assert (abs(out[360, 450].astype(int) - [200, 160, 130]) < 3).all(), "face must stay original"
assert (abs(out[700, 450].astype(int) - [150, 30, 30]) < 25).all(), "body must come from the generation"

full_person = Image.new("RGB", (600, 900), (40, 60, 120))
assert E.crop_to_person(full_person, parse)[1] is None, "no crop when the person fills the photo"
print("enhance tests OK")
