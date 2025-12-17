import os
import sys
from pathlib import Path

import cv2
import numpy as np
from fastapi import FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse

REPO_ROOT = Path(__file__).resolve().parents[1]
FRINGE_PYTHON_PATH = REPO_ROOT / "diffraction_capture" / "assets" / "python"
if str(FRINGE_PYTHON_PATH) not in sys.path:
    sys.path.insert(0, str(FRINGE_PYTHON_PATH))

from fringe_eval import find_fringe_spacing, _resize_if_needed  # noqa: E402

max_upload_mb = float(os.getenv("MAX_UPLOAD_MB", "10"))
max_upload_bytes_env = os.getenv("MAX_UPLOAD_BYTES")
MAX_UPLOAD_BYTES = (
    int(max_upload_bytes_env) if max_upload_bytes_env else int(max_upload_mb * 1024 * 1024)
)
DEFAULT_PEAK_THRESHOLD = float(os.getenv("PEAK_THRESHOLD", "0.35"))
DEFAULT_MAX_STD_RATIO = float(os.getenv("MAX_SPACING_STD_RATIO", "0.2"))
DEFAULT_MIN_PEAKS = int(os.getenv("MIN_PEAK_COUNT", "3"))
DEFAULT_MAX_DIMENSION = int(os.getenv("MAX_FRAME_DIMENSION", "0"))

app = FastAPI(title="Diffraction Analyzer", version="0.1.0")


async def _read_limited_upload(upload: UploadFile) -> bytes:
    data = await upload.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Uploaded file exceeds limit of {MAX_UPLOAD_BYTES} bytes",
        )
    return data


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/analyze")
async def analyze(
    request: Request,
    file: UploadFile = File(..., description="Image frame to analyze"),
    peak_threshold: float = Query(
        DEFAULT_PEAK_THRESHOLD,
        description="Normalized peak threshold (0-1) for fringe detection.",
    ),
    max_std_ratio: float = Query(
        DEFAULT_MAX_STD_RATIO,
        description="Maximum allowed (std/mean) ratio for detected spacings.",
    ),
    min_peaks: int = Query(
        DEFAULT_MIN_PEAKS,
        description="Minimum required peaks to accept spacing measurement.",
    ),
    max_dimension: int = Query(
        DEFAULT_MAX_DIMENSION,
        description="Resize so the longest side does not exceed this many pixels (0 to disable).",
    ),
):
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > MAX_UPLOAD_BYTES:
                raise HTTPException(
                    status_code=413,
                    detail=f"Upload size exceeds {MAX_UPLOAD_BYTES} bytes",
                )
        except ValueError:
            pass

    data = await _read_limited_upload(file)

    array = np.frombuffer(data, np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    if image is None:
        raise HTTPException(status_code=400, detail="Could not decode image")

    image, resized = _resize_if_needed(image, max_dimension)
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)

    spacing, peaks = find_fringe_spacing(
        gray,
        peak_threshold=peak_threshold,
        max_std_ratio=max_std_ratio,
        min_peaks=min_peaks,
    )

    return JSONResponse(
        {
            "fringe_spacing_px": spacing,
            "peaks": peaks,
            "resized": resized,
            "dimensions": {"width": int(image.shape[1]), "height": int(image.shape[0])},
            "threshold": peak_threshold,
            "max_std_ratio": max_std_ratio,
            "min_peaks": min_peaks,
        }
    )
