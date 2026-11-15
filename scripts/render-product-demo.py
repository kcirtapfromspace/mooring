#!/usr/bin/env python3
"""Edit reviewed Mooring connection and graphical-desktop takes at recorded speed.

The JSON plan contains source aliases (connections or desktop), start, duration,
heading and optional crop [width, height, x, y]. Authentication stays out of the
inputs. Keep raw takes, plans and draft outputs outside Git until reviewed.
"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONT = "/System/Library/Fonts/Avenir Next.ttc"
PAPER = "#fff2f4"
INK = "#242726"


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path),
    ]))


def card(path, platform, heading, status):
    image = Image.new("RGB", (1440, 900), PAPER)
    draw = ImageDraw.Draw(image)
    icon = Image.open(ROOT / "site/assets/icon.png").convert("RGBA")
    icon = icon.resize((36, 36), getattr(Image, "Resampling", Image).LANCZOS)
    image.paste(icon, (28, 22), icon)
    draw.text((78, 25), "MOORING", font=ImageFont.truetype(FONT, 23, index=2), fill=INK)
    draw.text((264, 25), "Mac to " + platform, font=ImageFont.truetype(FONT, 23, index=7), fill=INK)
    draw.text((30, 68), heading, font=ImageFont.truetype(FONT, 24, index=2), fill=INK)
    draw.text((1410, 34), status, anchor="ra", font=ImageFont.truetype(FONT, 14, index=7), fill="#9d2443")
    draw.text((28, 878), "Real Mooring UI · Edited scenes at recorded speed · No audio · Computer details hidden",
              font=ImageFont.truetype(FONT, 11, index=7), fill="#565d58")
    image.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connections-source", type=Path, required=True)
    parser.add_argument("--desktop-source", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sources = {"connections": args.connections_source, "desktop": args.desktop_source}
    metadata = {}
    for alias, source in sources.items():
        if source.resolve() == args.output.resolve():
            parser.error("Output must not overwrite a source")
        info = probe(source)
        video = [s for s in info["streams"] if s["codec_type"] == "video"]
        if len(video) != 1 or (video[0]["width"], video[0]["height"]) != (1440, 900):
            parser.error("Expected 1440×900 window takes")
        metadata[alias] = float(info["format"]["duration"])
    scenes = json.loads(args.plan.read_text())
    total = 0
    for scene in scenes:
        start, duration = scene["start"], scene["duration"]
        if start < 0 or duration <= 0 or start + duration > metadata[scene["source"]]:
            parser.error("Scene is outside its source recording")
        if "crop" in scene:
            w, h, x, y = scene["crop"]
            if min(w, h) <= 0 or min(x, y) < 0 or x + w > 1440 or y + h > 900:
                parser.error("Crop is outside the recording")
        total += duration
    if not 1 <= total <= 60:
        parser.error("Choose a film from 1 to 60 seconds")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mooring-product-edit-") as directory:
        work = Path(directory)
        segments = []
        for index, scene in enumerate(scenes):
            still, segment = work / f"card-{index}.png", work / f"scene-{index}.mp4"
            card(still, args.platform, scene["heading"], args.status)
            filters = ["setpts=PTS-STARTPTS"]
            if scene.get("hide_connection_details"):
                # Hide endpoint/DNS fields while retaining the actual connection controls.
                filters += ["drawbox=x=360:y=330:w=850:h=185:color=0x242726:t=fill"]
            if "crop" in scene:
                filters += ["crop=" + ":".join(str(n) for n in scene["crop"])]
            filters += ["scale=1392:756:force_original_aspect_ratio=decrease", "setsar=1"]
            run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-loop", "1", "-i", still,
                "-ss", scene["start"], "-i", sources[scene["source"]],
                "-filter_complex", "[1:v]" + ",".join(filters) + "[clip];[0:v][clip]overlay=(W-w)/2:112:shortest=1[v]",
                "-map", "[v]", "-t", scene["duration"], "-an", "-c:v", "libx264", "-preset", "slow",
                "-crf", "21", "-pix_fmt", "yuv420p", "-r", "30", "-map_metadata", "-1", segment,
            ])
            segments.append(segment)
        listing = work / "scenes.txt"
        listing.write_text("".join(f"file '{path}'\n" for path in segments))
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
             "-i", listing, "-c", "copy", "-map_metadata", "-1", "-movflags", "+faststart", args.output])
    info = probe(args.output)
    assert len(info["streams"]) == 1 and info["streams"][0]["codec_name"] == "h264"
    assert abs(float(info["format"]["duration"]) - total) < .2
    assert args.output.stat().st_size < 5_000_000
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", min(total - .1, 6), "-i", args.output,
         "-frames:v", "1", "-q:v", "2", "-update", "1", args.output.with_name(args.output.stem + "-poster.jpg")])
    print(f"Rendered {total:g} seconds, {args.output.stat().st_size:,} bytes. Review before publication.")


if __name__ == "__main__":
    main()
