"""Create synthetic clips for local video-model evaluation; no user data is read."""
from pathlib import Path
import sys

import cv2
import numpy as np

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
cases = [
    ("left", (230, 0, 0), "7392"),
    ("still", (0, 180, 0), "2764"),
    ("right", (0, 0, 230), "4826"),
]
for direction, color, code in cases:
    path = output / f"{direction}.mp4"
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), 4, (640, 360))
    if not writer.isOpened():
        raise RuntimeError(f"Cannot create {path}")
    try:
        for index in range(24):
            frame = np.full((360, 640, 3), 255, np.uint8)
            x = 30 + index * 22 if direction == "right" else (536 - index * 22 if direction == "left" else 280)
            cv2.rectangle(frame, (x, 145), (x + 54, 205), color, -1)
            cv2.putText(frame, "PROJECT " + code, (30, 60), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 0), 2, cv2.LINE_AA)
            writer.write(frame)
    finally:
        writer.release()
    print(path)
