# Backend Docker Image

This Dockerfile installs Python 3.11 along with OpenCV, FastAPI, and Uvicorn to run a basic FastAPI application.

## Build

```bash
docker build -t diffraction-backend backend
```

## Run

Assuming your FastAPI application is defined as `app` inside `main.py` located in the same directory as your source code, run the container with:

```bash
docker run --rm -it -p 8000:8000 -v "$(pwd)":/app diffraction-backend
```

The application will be available at http://localhost:8000.
