# diffraction_capture

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Python backend for slit analysis

The `backend/` directory contains a FastAPI server that accepts diffraction
images, measures the slit width with OpenCV, and returns results over HTTP so
the Flutter app can consume them (for example, using the provided `dio`
client helper in `lib/backend/backend_client.dart`).

To run the server locally:

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```
