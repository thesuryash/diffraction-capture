import io

import sys
from pathlib import Path

import numpy as np
from fastapi.testclient import TestClient
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app import _estimate_slit_width, app


def _synthetic_band_image(width: int = 80, height: int = 80, band_width: int = 14):
    image = np.zeros((height, width), dtype=np.uint8)
    start = (width - band_width) // 2
    image[:, start : start + band_width] = 255
    return image


def test_estimate_slit_width_matches_band():
    gray = _synthetic_band_image()
    estimated = _estimate_slit_width(gray)
    assert estimated is not None
    assert abs(estimated - 14) <= 1


def test_analyze_endpoint_returns_width():
    gray = _synthetic_band_image()
    image = Image.fromarray(gray)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    buffer.seek(0)

    client = TestClient(app)
    response = client.post("/analyze", files={"file": ("synthetic.png", buffer.getvalue(), "image/png")})

    assert response.status_code == 200, response.text
    payload = response.json()
    assert "slit_width_px" in payload
    assert abs(payload["slit_width_px"] - 14) <= 1
