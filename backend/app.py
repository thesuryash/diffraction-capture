import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGINS_ENV = "ALLOWED_ORIGINS"

def _allowed_origins() -> list[str]:
    raw_origins = os.getenv(ALLOWED_ORIGINS_ENV, "")
    origins = [origin.strip() for origin in raw_origins.split(",") if origin.strip()]
    if origins:
        return origins
    return ["*"]

app = FastAPI(title="Diffraction Capture API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health", tags=["health"])
def health_check():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"message": "Welcome to the Diffraction Capture API"}
