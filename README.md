# diffraction_capture

A new Flutter project with a FastAPI backend.

## Backend (FastAPI)

The backend lives in `backend/`. To set up:

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

Run uvicorn on the non-default host and port required for containerized deployments:

```bash
uvicorn backend.app:app --host 0.0.0.0 --port 8000
```

Set `ALLOWED_ORIGINS` to a comma-separated list to restrict CORS (defaults to allowing all origins):

```bash
ALLOWED_ORIGINS="http://localhost:8080,http://localhost:3000" uvicorn backend.app:app --host 0.0.0.0 --port 8000
```

## Flutter client

This project is a starting point for a Flutter application. For help getting started with Flutter development, view the [online documentation](https://docs.flutter.dev/), which offers tutorials, samples, guidance on mobile development, and a full API reference.
