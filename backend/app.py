from __future__ import annotations

from io import BytesIO
from typing import Optional

import numpy as np
from fastapi import FastAPI, File, HTTPException, UploadFile
from PIL import Image

app = FastAPI()


def _estimate_slit_width(gray: np.ndarray, threshold_ratio: float = 0.6) -> Optional[float]:
    if gray.ndim == 3:
        gray = np.mean(gray, axis=2)

    if gray.size == 0:
        return None

    profile = np.mean(gray.astype(np.float32), axis=0)
    max_val = float(np.max(profile))
    if max_val <= 0:
        return None

    mask = profile >= (max_val * threshold_ratio)
    if not np.any(mask):
        return None

    max_run = current_run = 0
    for flag in mask:
        if flag:
            current_run += 1
            max_run = max(max_run, current_run)
        else:
            current_run = 0

    return float(max_run) if max_run > 0 else None


@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
    try:
        contents = await file.read()
        image = Image.open(BytesIO(contents)).convert("L")
        gray = np.array(image, dtype=np.float32)
    except Exception as exc:  # pylint: disable=broad-except
        raise HTTPException(status_code=400, detail="Invalid image upload") from exc

    width = _estimate_slit_width(gray)
    if width is None:
        raise HTTPException(status_code=422, detail="Unable to estimate slit width")

    return {"slit_width_px": width}
