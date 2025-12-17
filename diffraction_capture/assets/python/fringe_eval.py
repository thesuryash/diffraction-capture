import argparse
import json
import os
import sys

import cv2
import numpy as np


DEFAULT_PEAK_THRESHOLD = float(os.getenv("PEAK_THRESHOLD", "0.35"))
DEFAULT_MAX_STD_RATIO = float(os.getenv("MAX_SPACING_STD_RATIO", "0.2"))
DEFAULT_MIN_PEAKS = int(os.getenv("MIN_PEAK_COUNT", "3"))
DEFAULT_MAX_DIMENSION = int(os.getenv("MAX_FRAME_DIMENSION", "0"))


def _resize_if_needed(image: np.ndarray, max_dimension: int):
    if max_dimension <= 0:
        return image, False

    height, width = image.shape[:2]
    largest_side = max(height, width)
    if largest_side <= max_dimension:
        return image, False

    scale = max_dimension / largest_side
    new_size = (int(width * scale), int(height * scale))
    resized = cv2.resize(image, new_size, interpolation=cv2.INTER_AREA)
    return resized, True


def find_fringe_spacing(
    gray: np.ndarray,
    peak_threshold: float = DEFAULT_PEAK_THRESHOLD,
    max_std_ratio: float = DEFAULT_MAX_STD_RATIO,
    min_peaks: int = DEFAULT_MIN_PEAKS,
):
    profile = np.mean(gray, axis=0)
    profile = profile - np.min(profile)
    max_val = np.max(profile)
    if max_val > 0:
        profile = profile / max_val

    threshold = max(0.0, min(1.0, peak_threshold))
    peaks = []
    for i in range(1, len(profile) - 1):
        val = profile[i]
        if val >= profile[i - 1] and val >= profile[i + 1] and val >= threshold:
            if not peaks or i - peaks[-1] > 2:
                peaks.append(i)

    spacings = [peaks[i] - peaks[i - 1] for i in range(1, len(peaks)) if peaks[i] - peaks[i - 1] > 1]
    if len(spacings) < 2 or len(peaks) < min_peaks:
        return None, peaks

    avg = float(np.mean(spacings))
    std = float(np.std(spacings))
    if avg <= 0 or (std / avg) > max_std_ratio:
        return None, peaks

    return avg, peaks


def main():
    parser = argparse.ArgumentParser(description="Detect fringe spacing in an image")
    parser.add_argument("image_path", help="Path to the image to analyze")
    parser.add_argument("overlay_path", nargs="?", help="Optional path to save overlay")
    parser.add_argument(
        "--peak-threshold",
        type=float,
        default=DEFAULT_PEAK_THRESHOLD,
        help="Normalized peak threshold (0-1) for fringe detection.",
    )
    parser.add_argument(
        "--max-std-ratio",
        type=float,
        default=DEFAULT_MAX_STD_RATIO,
        help="Maximum allowed standard deviation / mean ratio for spacing validity.",
    )
    parser.add_argument(
        "--min-peaks",
        type=int,
        default=DEFAULT_MIN_PEAKS,
        help="Minimum number of peaks required to accept a measurement.",
    )
    parser.add_argument(
        "--max-dimension",
        type=int,
        default=DEFAULT_MAX_DIMENSION,
        help="Resize the image so neither dimension exceeds this value (pixels).",
    )

    args = parser.parse_args()

    image_path = args.image_path
    overlay_path = args.overlay_path

    image = cv2.imread(image_path)
    if image is None:
        print(json.dumps({"error": "unable to read image"}))
        return

    image, resized = _resize_if_needed(image, args.max_dimension)
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    spacing, peaks = find_fringe_spacing(
        gray,
        peak_threshold=args.peak_threshold,
        max_std_ratio=args.max_std_ratio,
        min_peaks=args.min_peaks,
    )

    overlay_saved = False
    if overlay_path:
        overlay = cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)
        cv2.addWeighted(image, 0.6, overlay, 0.4, 0, overlay)
        if peaks:
            for idx, x in enumerate(peaks):
                cv2.line(overlay, (x, 0), (x, overlay.shape[0] - 1), (0, 255, 0), 1)
                if idx > 0:
                    gap = peaks[idx] - peaks[idx - 1]
                    label_y = 18 + (idx % 2) * 14
                    cv2.putText(
                        overlay,
                        f"{gap}px",
                        (int((peaks[idx] + peaks[idx - 1]) / 2), label_y),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.45,
                        (255, 0, 0),
                        1,
                        cv2.LINE_AA,
                    )
        cv2.imwrite(overlay_path, overlay)
        overlay_saved = True

    print(
        json.dumps(
            {
                "fringe_spacing_px": spacing,
                "peaks": peaks,
                "overlay_saved": overlay_saved,
                "resized": resized,
                "dimensions": {"width": int(image.shape[1]), "height": int(image.shape[0])},
                "threshold": args.peak_threshold,
                "max_std_ratio": args.max_std_ratio,
                "min_peaks": args.min_peaks,
            }
        )
    )


if __name__ == "__main__":
    main()
