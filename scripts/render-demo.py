#!/usr/bin/env python3
"""Edit the two local, privacy-reviewed recordings into the public demo.

Requires ffmpeg, ffprobe and Pillow. Source recordings stay outside tracked
source. Review the complete output before publishing; this is not a recorder.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
PAPER = "#fff2f4"
INK = "#242726"
MUTED = "#565d58"
YELLOW = "#ffd447"
FONT = "/System/Library/Fonts/Avenir Next.ttc"
SERIF = "/System/Library/Fonts/Palatino.ttc"


def run(args):
    subprocess.run([str(arg) for arg in args], check=True)


def text(draw, position, copy, size, fill=INK, serif=False):
    font = ImageFont.truetype(SERIF if serif else FONT, size, index=0 if serif else 7)
    draw.text(position, copy, font=font, fill=fill)


def frame(path, heading, subheading, footer, chapter, *, closing=False):
    image = Image.new("RGB", (1440, 900), PAPER)
    draw = ImageDraw.Draw(image)
    resampling = getattr(Image, "Resampling", Image)
    icon = Image.open(ROOT / "site/assets/icon.png").convert("RGBA").resize((40, 40), resampling.LANCZOS)
    image.paste(icon, (68, 49), icon)
    text(draw, (122, 51), "MOORING", 23)
    text(draw, (1140, 55), chapter, 18, MUTED)
    if closing:
        text(draw, (110, 245), heading, 88, serif=True)
        text(draw, (115, 470), subheading, 30, MUTED)
        draw.rounded_rectangle((112, 555, 1328, 639), radius=10, fill=YELLOW)
        text(draw, (143, 574), "kcirtapfromspace.github.io/mooring", 37)
    else:
        text(draw, (68, 115), heading, 53, serif=True)
        text(draw, (72, 199), subheading, 25, MUTED)
    text(draw, (72, 792), footer, 23, MUTED)
    draw.line((72, 860, 1368, 860), fill="#d9c9ca", width=2)
    image.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notch-source", type=Path, required=True)
    parser.add_argument("--sharing-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "site/assets/demo.mp4")
    args = parser.parse_args()
    for path in (args.notch_source, args.sharing_source):
        if not path.is_file():
            parser.error(f"Missing recording: {path}")
    for executable in ("ffmpeg", "ffprobe"):
        if not shutil.which(executable):
            parser.error(f"Missing executable: {executable}")
    for source, width, height, minimum in (
        (args.notch_source, 2880, 1620, 23),
        (args.sharing_source, 1440, 900, 55),
    ):
        details = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_streams", "-show_format", "-of", "json", str(source),
        ]))
        streams = details.get("streams", [])
        if not streams or (streams[0]["width"], streams[0]["height"]) != (width, height):
            parser.error(f"Expected a {width}×{height} recording: {source}")
        if float(details["format"]["duration"]) < minimum:
            parser.error(f"Recording must be at least {minimum} seconds: {source}")
    if args.output.resolve() in (args.notch_source.resolve(), args.sharing_source.resolve()):
        parser.error("Output must not overwrite either source recording")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    scenes = [
        (None, 0, 2, "Your Macs, within reach.", "Native remote desktop for Mac.", "Free and open source. An early preview.", "PREVIEW", ""),
        (args.notch_source, 0, 3, "A familiar full-screen problem.", "The other Mac’s desktop stops below the camera.", "Before · Recorded on a MacBook with a camera notch.", "01 / BEFORE", "crop=2880:810:0:510,scale=1360:382"),
        (args.notch_source, 4, 9, "Make room for your other Mac.", "Its menu bar moves up. Its icons make room for the notch.", "After · Real preview footage, at its recorded speed.", "02 / AFTER", "crop=2880:810:0:510,scale=1360:382"),
        (args.notch_source, 17, 6, "Its menus. Your MacBook screen.", "Open menus on either side of the camera.", "Remote control · The pointer and menus act on the other Mac.", "03 / CONTROL", "crop=2880:810:0:510,scale=1360:382"),
        (args.sharing_source, 50, 5, "Your Mac. The access you choose.", "Share with paired Macs. Stop sharing when you’re done.", "Recorded preview UI · Pairing now also supports a six-character PIN.", "04 / SHARE", "crop=560:640:440:70,scale=420:480"),
        (None, 0, 5, "Your Macs,\nwithin reach.", "Download the free, open-source preview.", "Apple silicon · macOS 14+ · Signed and notarized", "TRY MOORING", ""),
    ]
    encode = ["-an", "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-pix_fmt", "yuv420p", "-r", "30", "-map_metadata", "-1", "-movflags", "+faststart"]
    with tempfile.TemporaryDirectory(prefix="mooring-demo-") as temporary:
        work = Path(temporary)
        segments = []
        for index, (source, start, duration, heading, subheading, footer, chapter, crop) in enumerate(scenes):
            still = work / f"frame-{index}.png"
            segment = work / f"segment-{index}.mp4"
            frame(still, heading, subheading, footer, chapter, closing=index == 5)
            command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-loop", "1", "-framerate", "30", "-i", still]
            if source:
                command += ["-ss", start, "-i", source]
                y = 280 if index == 4 else 320
                command += ["-filter_complex", f"[1:v]{crop},setsar=1,setpts=PTS-STARTPTS[clip];[0:v][clip]overlay=(W-w)/2:{y}:shortest=1[v]", "-map", "[v]"]
            else:
                command += ["-vf", "setsar=1"]
            command += ["-t", duration, *encode, segment]
            run(command)
            segments.append(segment)
        listing = work / "segments.txt"
        listing.write_text("".join(f"file '{segment}'\n" for segment in segments))
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", "-map_metadata", "-1", "-movflags", "+faststart", args.output])
    poster = args.output.with_name("demo-poster.jpg")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "10", "-i", args.output, "-frames:v", "1", "-q:v", "2", "-update", "1", poster])
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(args.output)])
    metadata = json.loads(probe)
    assert len(metadata["streams"]) == 1, "Demo must have one video stream and no audio"
    stream = metadata["streams"][0]
    assert (stream["codec_name"], stream["width"], stream["height"]) == ("h264", 1440, 900)
    assert 29.9 <= float(metadata["format"]["duration"]) <= 30.2
    assert args.output.stat().st_size < 5_000_000, "Demo exceeds the site's 5 MB budget"
    print(f"Rendered {args.output} ({args.output.stat().st_size:,} bytes, 30 seconds)")
    print("Review the entire video for privacy and visual quality before publication.")


if __name__ == "__main__":
    main()
