# Diffraction Capture Backend

This directory hosts a lightweight FastAPI server that accepts diffraction
images, estimates slit width with OpenCV, and returns the measurement over HTTP
for the Flutter client (via `dio` or the `http` package).

## Quickstart

1. Create a virtual environment and install dependencies:

   ```bash
   python -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

2. Start the server (hot-reload enabled):

   ```bash
   uvicorn app:app --host 0.0.0.0 --port 8000 --reload
   ```

3. Send an image from Flutter or curl:

   ```bash
   curl -X POST "http://localhost:8000/analyze" \
     -F "image=@/path/to/image.jpg" \
     -F "pixel_size=0.0042"
   ```

   The response includes the detected width in pixels and, when `pixel_size` is
   provided, a physical width value.

## API

- `GET /health` — Simple health probe.
- `POST /analyze` — Accepts a multipart form with `image` (required) and
  `pixel_size` (optional). Uses an intensity profile to detect the brightest
  slit-like feature.
