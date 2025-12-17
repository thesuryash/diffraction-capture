FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# System dependencies required by OpenCV
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
RUN pip install --no-cache-dir \
    fastapi \
    uvicorn[standard] \
    opencv-python

EXPOSE 8000

# Default command for running a FastAPI app named "app" in main.py
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
