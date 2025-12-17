"""FastAPI backend for diffraction slit analysis.

This server exposes HTTP endpoints that Flutter can call via `dio` or `http`.
It uses OpenCV to inspect uploaded images and estimate slit width based on the
brightest band in the frame.
"""

from __future__ import annotations

from typing import Optional

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Diffraction Capture Backend", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> dict[str, str]:
    """Basic health check endpoint."""

    return {"status": "ok"}


def _load_image(upload: UploadFile) -> np.ndarray:
    data = upload.file.read()
    if not data:
        raise ValueError("Image payload was empty")
    array = np.frombuffer(data, dtype=np.uint8)
    frame = cv2.imdecode(array, cv2.IMREAD_COLOR)
    if frame is None:
        raise ValueError("Could not decode the uploaded image")
    return frame


def _estimate_slit_width(frame: np.ndarray) -> float:
    """Estimate slit width in pixels using a column intensity profile.

    The image is converted to grayscale, lightly blurred to reduce noise, and a
    horizontal intensity profile is computed by averaging rows. The brightest
    run in the profile is used to derive the slit width.
    """

    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)

    # Normalize to the range [0, 1] to make threshold selection robust.
    normalized = cv2.normalize(blurred.astype(np.float32), None, 0.0, 1.0, cv2.NORM_MINMAX)
    profile = normalized.mean(axis=0)

    smooth_profile = cv2.GaussianBlur(profile.reshape(1, -1), (1, 21), 0).ravel()
    max_value = float(smooth_profile.max())
    if max_value <= 0.0:
        raise ValueError("Image is too dark to locate a slit")

    threshold = max_value * 0.5
    above = smooth_profile >= threshold

    best_width = 0
    current_width = 0
    for value in above:
        if value:
            current_width += 1
            best_width = max(best_width, current_width)
        else:
            current_width = 0

    if best_width == 0:
        raise ValueError("No bright slit-like region detected")

    return float(best_width)


def _normalize_pixel_size(pixel_size: Optional[float]) -> Optional[float]:
    if pixel_size is None:
        return None
    if pixel_size <= 0:
        raise ValueError("pixel_size must be positive when provided")
    return pixel_size


@app.post("/analyze")
def analyze(  # noqa: D417 - FastAPI expects parameters to be documented via request models
    image: UploadFile = File(..., description="Captured diffraction image"),
    pixel_size: Optional[float] = Form(
        None,
        description="Optional physical size for a single pixel (e.g. mm per pixel)",
    ),
) -> dict[str, Optional[float]]:
    """Analyze a diffraction image and estimate slit width.

    Returns the detected width in pixels and, when a `pixel_size` is provided,
    the physical width.
    """

    try:
        frame = _load_image(image)
        size_per_pixel = _normalize_pixel_size(pixel_size)
        width_pixels = _estimate_slit_width(frame)
    except ValueError as exc:  # pragma: no cover - FastAPI handles conversion
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    width_physical = width_pixels * size_per_pixel if size_per_pixel is not None else None

    return {
        "width_pixels": width_pixels,
        "width_physical": width_physical,
        "pixel_size": size_per_pixel,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=True)
