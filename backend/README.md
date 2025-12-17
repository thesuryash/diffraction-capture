# Backend API

This FastAPI service powers the Diffraction Capture project. Use the steps below to set up a local environment, install dependencies, and run the server.

## Setup

1. Create a virtual environment in the backend directory:
   ```bash
   python -m venv .venv
   ```
2. Activate the environment:
   - macOS/Linux: `source .venv/bin/activate`
   - Windows: `.venv\\Scripts\\activate`
3. Install dependencies:
   ```bash
   pip install --upgrade pip
   pip install -r requirements.txt
   ```

## Running the server

Start uvicorn on the intended host and port so it is reachable by the Flutter client. Run this from the repository root:
```bash
uvicorn backend.app:app --host 0.0.0.0 --port 8000
```
If you run the command from within `backend/`, target the module directly:
```bash
uvicorn app:app --host 0.0.0.0 --port 8000
```
The host value `0.0.0.0` is required for container or remote deployments because uvicorn defaults to binding only to `127.0.0.1`.

## CORS configuration

Allowed origins are controlled with the `ALLOWED_ORIGINS` environment variable. Provide a comma-separated list (no spaces) to restrict access:
```bash
ALLOWED_ORIGINS="http://localhost:8080,http://localhost:3000" uvicorn backend.app:app --host 0.0.0.0 --port 8000
```
If `ALLOWED_ORIGINS` is not set, all origins are allowed for development convenience.
