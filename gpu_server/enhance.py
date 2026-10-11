"""Quality helpers around FASHN VTON 1.5 (no extra pip packages needed).

FASHN generates at most 576x864 pixels. A phone photo is 3-4x larger, and the face,
glasses and background lose detail when the whole result is shown at that size. So:

1. crop_to_person  - the person is cropped (with margin, 2:3) before try-on, so more
                     of the 576x864 budget goes to the body and the garment;
2. Upscaler        - Real-ESRGAN x4plus sharpens the generated crop (RRDBNet below);
3. composite       - the result goes back into the ORIGINAL photo: background, face and
                     hair stay the original sharp pixels, only the clothed body is taken
                     from the generation (soft-edged mask from the human parser).

Every step is optional and falls back to the plain FASHN output on any error.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Callable

import cv2
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from torch import nn

# FashnHumanParser label ids
BACKGROUND = 0
FACE = 1
HAIR = 2
GLASSES = 11
MODEL_ASPECT = 576 / 864  # width / height of the FASHN canvas

ESRGAN_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"


# --------------------------------------------------------------------------- #
# Real-ESRGAN (RRDBNet, same layer names as basicsr so the official weights load)
# --------------------------------------------------------------------------- #
class _ResidualDenseBlock(nn.Module):
    def __init__(self, nf: int = 64, gc: int = 32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class _RRDB(nn.Module):
    def __init__(self, nf: int, gc: int = 32):
        super().__init__()
        self.rdb1 = _ResidualDenseBlock(nf, gc)
        self.rdb2 = _ResidualDenseBlock(nf, gc)
        self.rdb3 = _ResidualDenseBlock(nf, gc)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, nf: int = 64, nb: int = 23, gc: int = 32):
        super().__init__()
        self.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        self.body = nn.Sequential(*[_RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, inplace=True)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


class Upscaler:
    """Real-ESRGAN x4plus with tiling (a 576x864 image takes ~1-2 s on an RTX 4060)."""

    def __init__(self, weights_path: str | Path, device: str = "cuda", tile: int = 384):
        self.device = torch.device(device)
        self.tile = tile
        self.half = self.device.type == "cuda"
        state = torch.load(str(weights_path), map_location="cpu", weights_only=True)
        state = state.get("params_ema") or state.get("params") or state
        model = RRDBNet()
        model.load_state_dict(state, strict=True)
        model.eval().to(self.device)
        self.model = model.half() if self.half else model

    @torch.inference_mode()
    def __call__(self, image: Image.Image) -> Image.Image:
        arr = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
        x = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0).to(self.device)
        if self.half:
            x = x.half()
        _, _, h, w = x.shape
        out = torch.zeros((1, 3, h * 4, w * 4), dtype=x.dtype, device=self.device)
        pad = 16
        for y0 in range(0, h, self.tile):
            for x0 in range(0, w, self.tile):
                y1, x1 = min(y0 + self.tile, h), min(x0 + self.tile, w)
                py0, px0 = max(y0 - pad, 0), max(x0 - pad, 0)
                py1, px1 = min(y1 + pad, h), min(x1 + pad, w)
                tile_out = self.model(x[:, :, py0:py1, px0:px1])
                oy, ox = (y0 - py0) * 4, (x0 - px0) * 4
                out[:, :, y0 * 4:y1 * 4, x0 * 4:x1 * 4] = tile_out[
                    :, :, oy:oy + (y1 - y0) * 4, ox:ox + (x1 - x0) * 4
                ]
        result = out.squeeze(0).float().clamp_(0, 1).permute(1, 2, 0).cpu().numpy()
        return Image.fromarray((result * 255.0).round().astype(np.uint8))


def load_upscaler(weights_dir: str | Path, device: str = "cuda") -> Upscaler | None:
    """Downloads the weights once (64 MB). Returns None if anything fails."""
    if os.getenv("FITME_UPSCALE", "1").strip() in {"0", "false", "no"}:
        return None
    path = Path(weights_dir) / "RealESRGAN_x4plus.pth"
    try:
        if not path.exists() or path.stat().st_size < 60_000_000:
            import urllib.request

            print("Downloading Real-ESRGAN x4plus (64 MB)...")
            tmp = path.with_suffix(".part")
            urllib.request.urlretrieve(ESRGAN_URL, tmp)
            tmp.replace(path)
        return Upscaler(path, device=device)
    except Exception as exc:  # the try-on must work without the upscaler
        print(f"Upscaler disabled: {type(exc).__name__}: {exc}")
        return None


# --------------------------------------------------------------------------- #
# Crop / composite
# --------------------------------------------------------------------------- #
def person_box(seg: np.ndarray, scale_x: float, scale_y: float, size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    """Box around the person (2:3 like the FASHN canvas) in full-image pixels."""
    ys, xs = np.nonzero(seg != BACKGROUND)
    if len(xs) < 50:
        return None
    w, h = size
    x0, x1 = xs.min() * scale_x, (xs.max() + 1) * scale_x
    y0, y1 = ys.min() * scale_y, (ys.max() + 1) * scale_y
    bh = y1 - y0
    margin = 0.07 * bh
    x0, x1, y0, y1 = x0 - margin, x1 + margin, y0 - margin, y1 + margin
    bw, bh = x1 - x0, y1 - y0
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if bw / bh < MODEL_ASPECT:
        bw = bh * MODEL_ASPECT
    else:
        bh = bw / MODEL_ASPECT
    bw, bh = min(bw, w), min(bh, h)
    left = int(round(min(max(cx - bw / 2, 0), w - bw)))
    top = int(round(min(max(cy - bh / 2, 0), h - bh)))
    return left, top, left + int(round(bw)), top + int(round(bh))


def crop_to_person(
    image: Image.Image,
    parse: Callable[[np.ndarray], np.ndarray],
    analysis_side: int = 768,
) -> tuple[Image.Image, tuple[int, int, int, int] | None]:
    """Returns (crop, box). box is None when cropping would not help."""
    w, h = image.size
    small = image.copy()
    small.thumbnail((analysis_side, analysis_side), Image.Resampling.BILINEAR)
    seg = parse(np.asarray(small))
    box = person_box(seg, w / small.width, h / small.height, (w, h))
    if box is None:
        return image, None
    bw, bh = box[2] - box[0], box[3] - box[1]
    if bw * bh > 0.8 * w * h:  # the person already fills the photo
        return image, None
    return image.crop(box), box


def body_mask(seg_original: np.ndarray, seg_result: np.ndarray) -> np.ndarray:
    """1 where the generated pixels must be used (the dressed body), 0 where the
    original stays (background, and face/hair/glasses that the model did not change)."""
    person = (seg_original != BACKGROUND) | (seg_result != BACKGROUND)
    keep_head = np.isin(seg_original, (FACE, HAIR, GLASSES)) & np.isin(seg_result, (FACE, HAIR, GLASSES))
    return (person & ~keep_head).astype(np.float32)


def soft_mask(mask: np.ndarray, size: tuple[int, int], grow: float = 0.012, feather: float = 0.008) -> np.ndarray:
    """Grow + blur the mask (relative to image height) and resize it to `size` (w, h)."""
    h = mask.shape[0]
    g = max(1, int(round(h * grow)))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * g + 1, 2 * g + 1))
    grown = cv2.dilate(mask, kernel)
    f = max(1, int(round(h * feather))) * 2 + 1
    soft = cv2.GaussianBlur(grown, (f, f), 0)
    return cv2.resize(soft, size, interpolation=cv2.INTER_LINEAR)


def match_colors(result: np.ndarray, original: np.ndarray, region: np.ndarray) -> np.ndarray:
    """Tiny per-channel brightness shift so the generated body matches the original
    lighting at the seams (computed on background-free pixels kept from the original)."""
    if region.sum() < 500:
        return result
    r = result[region].astype(np.float32).mean(axis=0)
    o = original[region].astype(np.float32).mean(axis=0)
    shift = np.clip(o - r, -12, 12)
    return np.clip(result.astype(np.float32) + shift, 0, 255).astype(np.uint8)


def finish_result(
    original: Image.Image,
    crop_box: tuple[int, int, int, int] | None,
    generated: Image.Image,
    parse: Callable[[np.ndarray], np.ndarray],
    upscaler: Callable[[Image.Image], Image.Image] | None = None,
) -> Image.Image:
    """Puts the generated crop back into the original photo at full resolution."""
    region = original if crop_box is None else original.crop(crop_box)
    rw, rh = region.size

    gen = generated.convert("RGB")
    # FASHN output keeps the aspect of its input; guard against 1-2 px rounding.
    small_region = region.resize(gen.size, Image.Resampling.LANCZOS)

    seg_gen = parse(np.asarray(gen))
    seg_orig = parse(np.asarray(small_region))
    mask_small = body_mask(seg_orig, seg_gen)

    if upscaler is not None and rw > gen.width * 1.15:
        try:
            sharp = upscaler(gen).resize((rw, rh), Image.Resampling.LANCZOS)
            plain = gen.resize((rw, rh), Image.Resampling.LANCZOS)
            up = Image.blend(plain, sharp, 0.8)  # a touch softer than pure ESRGAN
        except Exception as exc:
            print(f"Upscale failed, using Lanczos: {exc}")
            up = gen.resize((rw, rh), Image.Resampling.LANCZOS)
    else:
        up = gen.resize((rw, rh), Image.Resampling.LANCZOS)

    alpha = soft_mask(mask_small, (rw, rh))[..., None]
    region_np = np.asarray(region, dtype=np.uint8)
    up_np = np.asarray(up, dtype=np.uint8)

    # Seams: compare the original and generated pixels on the head we keep.
    seam = cv2.resize(
        (np.isin(seg_orig, (FACE,)) & np.isin(seg_gen, (FACE,))).astype(np.uint8),
        (rw, rh),
        interpolation=cv2.INTER_NEAREST,
    ).astype(bool)
    up_np = match_colors(up_np, region_np, seam)

    merged = (up_np.astype(np.float32) * alpha + region_np.astype(np.float32) * (1.0 - alpha))
    merged_img = Image.fromarray(np.clip(merged, 0, 255).round().astype(np.uint8))

    if crop_box is None:
        return merged_img
    out = original.copy()
    out.paste(merged_img, crop_box[:2])
    return out


