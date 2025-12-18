#!/usr/bin/env python3
"""
Batch fringe-spacing analyzer with 2-step workflow (CLI or popup):

1) Calibration photo:
   - Opens the image in an OpenCV window
   - Click 2 points that span a known real length
   - Enter that length (mm)
   => computes mm_per_px (pixel pitch on the *imaged plane*, i.e., screen/cardboard plane)

2) Session root folder:
   - Recursively scans images
   - Estimates fringe spacing (px) via edge-profile autocorrelation
   - Converts to mm using mm_per_px
   - Optionally computes slit width if wavelength + slit-to-screen provided
   - Saves CSV + overlay/edges images into _analysis_out

Dependencies:
  pip install opencv-python numpy

Run:
  python3 measure_fringes.py --cli
  python3 measure_fringes.py --popup   (macOS AppleScript dialogs; may crash on some setups)
"""

import os
import csv
import math
import argparse
import numpy as np
import cv2
import subprocess
import shlex


# -----------------------------
# UI helpers (CLI or Popup)
# -----------------------------
def build_ui(mode: str):
    """
    mode: 'cli' or 'popup'
    Returns: pick_file, pick_folder, ask_float, info, warn
    """

    # ---- CLI versions ----
    def pick_file_cli(title: str, filetypes=None):
        p = input(f"{title}\nPaste FULL path to file: ").strip()
        return p or None

    def pick_folder_cli(title: str):
        p = input(f"{title}\nPaste FULL path to folder: ").strip()
        return p or None

    def ask_float_cli(title: str, prompt: str, initial=None):
        default_txt = "" if initial is None else str(initial)
        s = input(f"{title}: {prompt} [{default_txt}] ").strip()
        if not s:
            return float(default_txt) if default_txt else None
        try:
            return float(s)
        except Exception:
            return None

    def info_cli(msg: str, title: str = "Info"):
        print(f"[{title}] {msg}")

    def warn_cli(msg: str, title: str = "Warning"):
        print(f"[{title}] {msg}")

    # ---- Popup (AppleScript) versions ----
    def _run_osascript(script: str) -> str:
        p = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip() or "Dialog cancelled")
        return p.stdout.strip()

    def pick_file_popup(title: str, filetypes=None):
        try:
            script = f"""
            set theFile to choose file with prompt {shlex.quote(title)}
            POSIX path of theFile
            """
            return _run_osascript(script)
        except Exception:
            return None

    def pick_folder_popup(title: str):
        try:
            script = f"""
            set theFolder to choose folder with prompt {shlex.quote(title)}
            POSIX path of theFolder
            """
            return _run_osascript(script)
        except Exception:
            return None

    def ask_float_popup(title: str, prompt: str, initial=None):
        try:
            default_txt = "" if initial is None else str(initial)
            script = f"""
            set theAnswer to text returned of (display dialog {shlex.quote(prompt)} with title {shlex.quote(title)} default answer {shlex.quote(default_txt)})
            theAnswer
            """
            s = _run_osascript(script)
            return float(s)
        except Exception:
            return None

    def info_popup(msg: str, title: str = "Info"):
        try:
            script = f'display dialog {shlex.quote(msg)} with title {shlex.quote(title)} buttons {{"OK"}} default button "OK"'
            _run_osascript(script)
        except Exception:
            pass

    def warn_popup(msg: str, title: str = "Warning"):
        try:
            script = f'display dialog {shlex.quote(msg)} with title {shlex.quote(title)} buttons {{"OK"}} default button "OK" with icon caution'
            _run_osascript(script)
        except Exception:
            pass

    if mode == "cli":
        return pick_file_cli, pick_folder_cli, ask_float_cli, info_cli, warn_cli
    else:
        return pick_file_popup, pick_folder_popup, ask_float_popup, info_popup, warn_popup


# -----------------------------
# Calibration: click 2 points
# -----------------------------
def pick_two_points(image_bgr, window="Calibration: click 2 endpoints (press ESC to cancel)"):
    img = image_bgr.copy()
    h, w = img.shape[:2]
    scale = 1.0
    max_w = 1200
    if w > max_w:
        scale = max_w / w
        img = cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)

    pts = []

    def on_mouse(event, x, y, flags, param):
        nonlocal pts, img
        if event == cv2.EVENT_LBUTTONDOWN:
            pts.append((x, y))
            cv2.circle(img, (x, y), 6, (0, 255, 255), -1)
            if len(pts) == 2:
                cv2.line(img, pts[0], pts[1], (0, 255, 255), 2)

    cv2.namedWindow(window, cv2.WINDOW_NORMAL)
    cv2.setMouseCallback(window, on_mouse)

    while True:
        cv2.imshow(window, img)
        key = cv2.waitKey(20) & 0xFF
        if key == 27:  # ESC
            cv2.destroyWindow(window)
            return None
        if len(pts) >= 2:
            cv2.waitKey(300)
            cv2.destroyWindow(window)
            # map back to original coords
            p0 = (pts[0][0] / scale, pts[0][1] / scale)
            p1 = (pts[1][0] / scale, pts[1][1] / scale)
            return p0, p1


def mm_per_px_from_calibration(calib_path, ask_float):
    img = cv2.imread(calib_path, cv2.IMREAD_COLOR)
    if img is None:
        raise RuntimeError(f"Could not read calibration image: {calib_path}")

    pts = pick_two_points(img)
    if pts is None:
        raise RuntimeError("Calibration cancelled (no points selected).")

    known_mm = ask_float(
        "Calibration",
        "Enter the REAL length between the 2 clicked points (mm):",
        initial=10.0,
    )
    if known_mm is None or known_mm <= 0:
        raise RuntimeError("Invalid known length (mm).")

    (x0, y0), (x1, y1) = pts
    dist_px = math.hypot(x1 - x0, y1 - y0)
    if dist_px <= 0:
        raise RuntimeError("Invalid pixel distance (0).")

    return known_mm / dist_px


# -----------------------------
# Fringe spacing estimation
# -----------------------------
def estimate_fringe_spacing_px(image_bgr):
    """
    Returns (spacing_px, debug_edges_bgr) or (None, debug_edges_bgr)
    Method:
      - gray -> blur -> Canny
      - x-profile = sum of edge pixels along y
      - autocorrelation peak -> dominant spacing
    """
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)

    edges = cv2.Canny(gray, 50, 150)
    edges_vis = cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)

    profile = edges.sum(axis=0).astype(np.float32)
    if profile.size < 50 or profile.max() <= 0:
        return None, edges_vis

    profile = profile - profile.mean()
    if np.allclose(profile, 0):
        return None, edges_vis

    n = int(2 ** math.ceil(math.log2(len(profile) * 2)))
    f = np.fft.rfft(profile, n=n)
    ac = np.fft.irfft(f * np.conj(f), n=n)[: len(profile)]
    ac[0] = 0

    min_lag = max(5, int(len(profile) * 0.01))
    max_lag = min(len(profile) - 1, int(len(profile) * 0.5))
    if max_lag <= min_lag + 2:
        return None, edges_vis

    segment = ac[min_lag:max_lag]
    lag = int(np.argmax(segment) + min_lag)

    if ac[lag] <= 0:
        return None, edges_vis

    return float(lag), edges_vis


def draw_overlay_lines(image_bgr, spacing_px, color=(0, 255, 255), thickness=2):
    out = image_bgr.copy()
    h, w = out.shape[:2]
    s = int(round(spacing_px))
    if s <= 0:
        return out
    for x in range(s, w, s):
        cv2.line(out, (x, 0), (x, h - 1), color, thickness)
    return out


# -----------------------------
# Batch process
# -----------------------------
IMG_EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".heic")


def iter_images(root_dir):
    for dirpath, _, filenames in os.walk(root_dir):
        for fn in filenames:
            if fn.lower().endswith(IMG_EXTS):
                yield os.path.join(dirpath, fn)


def main():
    parser = argparse.ArgumentParser()
    g = parser.add_mutually_exclusive_group()
    g.add_argument("--cli", action="store_true", help="Use command-line prompts (no popups)")
    g.add_argument("--popup", action="store_true", help="Use macOS popups (AppleScript)")
    args = parser.parse_args()

    mode = "cli" if args.cli else "popup"  # default popup
    pick_file, pick_folder, ask_float, info, warn = build_ui(mode)

    print(f"--- Starting Fringe Analyzer (mode={mode}) ---")

    # Step 1: calibration
    calib = pick_file("Select CALIBRATION photo (contains a known-length line)")
    if not calib:
        return

    try:
        mm_per_px = mm_per_px_from_calibration(calib, ask_float)
    except Exception as e:
        warn(str(e), "Calibration failed")
        return

    info(f"Calibration complete:\nmm_per_px = {mm_per_px:.6f}", "Calibration OK")

    # Optional optics inputs (only if you want slit-width too)
    wavelength_nm = ask_float(
        "Optional",
        "Laser wavelength (nm) for slit-width calc? (Cancel/blank to skip)",
        initial=650.0,
    )
    slit_to_screen_mm = None
    if wavelength_nm is not None:
        slit_to_screen_mm = ask_float(
            "Optional",
            "Slit-to-screen distance (mm)? (Cancel/blank to skip)",
            initial=1000.0,
        )
        if slit_to_screen_mm is None:
            wavelength_nm = None

    # Step 2: session folder
    root_dir = pick_folder("Select SESSION ROOT folder (contains temp subfolders, images)")
    if not root_dir:
        return

    out_dir = os.path.join(root_dir, "_analysis_out")
    os.makedirs(out_dir, exist_ok=True)
    csv_path = os.path.join(out_dir, "fringe_analysis.csv")

    rows = []
    count = 0
    ok = 0

    for path in iter_images(root_dir):
        # skip analysis output folder
        try:
            if os.path.commonpath([path, out_dir]) == out_dir:
                continue
        except Exception:
            pass

        img = cv2.imread(path, cv2.IMREAD_COLOR)
        if img is None:
            continue

        count += 1
        spacing_px, edges_vis = estimate_fringe_spacing_px(img)
        spacing_mm = None
        slit_width_mm = None

        if spacing_px is not None:
            ok += 1
            spacing_mm = spacing_px * mm_per_px

            if wavelength_nm is not None and slit_to_screen_mm is not None and spacing_mm > 0:
                wavelength_mm = wavelength_nm * 1e-6  # nm -> mm
                slit_width_mm = (wavelength_mm * slit_to_screen_mm) / spacing_mm

            overlay = draw_overlay_lines(img, spacing_px)
            rel = os.path.relpath(path, root_dir).replace(os.sep, "__")
            cv2.imwrite(os.path.join(out_dir, f"overlay__{rel}.png"), overlay)
            cv2.imwrite(os.path.join(out_dir, f"edges__{rel}.png"), edges_vis)

        rows.append(
            {
                "image_path": os.path.relpath(path, root_dir),
                "spacing_px": "" if spacing_px is None else f"{spacing_px:.3f}",
                "spacing_mm": "" if spacing_mm is None else f"{spacing_mm:.6f}",
                "slit_width_mm": "" if slit_width_mm is None else f"{slit_width_mm:.6f}",
            }
        )

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(
            f, fieldnames=["image_path", "spacing_px", "spacing_mm", "slit_width_mm"]
        )
        writer.writeheader()
        writer.writerows(rows)

    info(
        f"Done.\n"
        f"Processed: {count} image(s)\n"
        f"Measured: {ok} image(s)\n\n"
        f"Output folder:\n{out_dir}\n\n"
        f"CSV:\n{csv_path}",
        "Batch complete",
    )


if __name__ == "__main__":
    main()