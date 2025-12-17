import json
import sys

import cv2
import numpy as np


def find_fringe_spacing(gray: np.ndarray):
    profile = np.mean(gray, axis=0)
    profile = profile - np.min(profile)
    max_val = np.max(profile)
    if max_val > 0:
        profile = profile / max_val

    threshold = 0.35
    peaks = []
    for i in range(1, len(profile) - 1):
        val = profile[i]
        if val >= profile[i - 1] and val >= profile[i + 1] and val >= threshold:
            if not peaks or i - peaks[-1] > 2:
                peaks.append(i)

    spacings = [peaks[i] - peaks[i - 1] for i in range(1, len(peaks)) if peaks[i] - peaks[i - 1] > 1]
    if len(spacings) < 2:
        return None, peaks

    avg = float(np.mean(spacings))
    std = float(np.std(spacings))
    if avg <= 0 or (std / avg) > 0.2:
        return None, peaks

    return avg, peaks


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "missing image path"}))
        return

    image_path = sys.argv[1]
    overlay_path = sys.argv[2] if len(sys.argv) > 2 else None

    image = cv2.imread(image_path)
    if image is None:
        print(json.dumps({"error": "unable to read image"}))
        return

    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    spacing, peaks = find_fringe_spacing(gray)

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
            }
        )
    )


if __name__ == "__main__":
    main()
