#!/usr/bin/env python3
"""Caption reviewed recordings of real Linux sessions, keeping recorded speed.

Requires ffmpeg, ffprobe and Pillow. Raw inputs must stay outside Git. Review
the complete outputs before copying them into site/assets for publication.
"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT = "/System/Library/Fonts/Avenir Next.ttc"


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", str(path),
    ]))


def caption(path, platform, status):
    image = Image.new("RGBA", (1440, 900), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 836, 1440, 900), fill="#242726")
    icon = Image.open(ROOT / "site/assets/icon.png").convert("RGBA")
    icon = icon.resize((34, 34), getattr(Image, "Resampling", Image).LANCZOS)
    image.alpha_composite(icon, (24, 850))
    draw.text((74, 847), platform,
              font=ImageFont.truetype(FONT, 23, index=7), fill="#fff2f4")
    draw.text((74, 877), "Real session · Recorded speed · No audio",
              font=ImageFont.truetype(FONT, 12, index=0), fill="#d6dbd7")
    draw.text((1408, 858), status, anchor="ra",
              font=ImageFont.truetype(FONT, 16, index=7), fill="#ffd447")
    image.save(path)


def render(source, output, start, duration, platform, status, poster_time):
    if not source.is_file():
        raise ValueError(f"Missing recording: {source}")
    if source.resolve() == output.resolve():
        raise ValueError("Output must not overwrite its source")
    info = probe(source)
    video = [s for s in info["streams"] if s["codec_type"] == "video"]
    if len(video) != 1 or (video[0]["width"], video[0]["height"]) != (1440, 900):
        raise ValueError("Expected one 1440×900 capture stream")
    if float(info["format"]["duration"]) < start + duration:
        raise ValueError("The source is shorter than the selected scene")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mooring-linux-edit-") as directory:
        overlay = Path(directory) / "caption.png"
        caption(overlay, platform, status)
        run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", start, "-i", source, "-loop", "1", "-i", overlay,
            "-filter_complex", "[0:v]setpts=PTS-STARTPTS[clip];[clip][1:v]overlay=0:0:shortest=1,setsar=1[v]",
            "-map", "[v]", "-t", duration, "-an", "-c:v", "libx264",
            "-preset", "slow", "-crf", "21", "-pix_fmt", "yuv420p", "-r", "30",
            "-map_metadata", "-1", "-movflags", "+faststart", output,
        ])
    details = probe(output)
    assert len(details["streams"]) == 1, "Expected silent video only"
    assert details["streams"][0]["codec_name"] == "h264"
    assert abs(float(details["format"]["duration"]) - duration) < .1
    assert output.stat().st_size < 5_000_000, "Film exceeds 5 MB budget"
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", poster_time, "-i", output, "-frames:v", "1", "-q:v", "2",
        "-update", "1", output.with_name(output.stem + "-poster.jpg"),
    ])
    print(f"Rendered {output.name}: {duration}s, {output.stat().st_size:,} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omarchy-source", type=Path, required=True)
    parser.add_argument("--x11-source", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    render(args.omarchy_source, args.output_directory / "omarchy-demo.mp4", 0, 24,
           "Omarchy / Hyprland", "Installed build 50", 1)
    render(args.x11_source, args.output_directory / "x11-development-demo.mp4", 3, 18,
           "Ubuntu / X11", "Local development build 50 · Not in preview 45", 13)
    print("Review both complete films and posters before publication.")


if __name__ == "__main__":
    main()
