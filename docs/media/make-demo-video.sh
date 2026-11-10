#!/usr/bin/env bash
# Builds the explainer video (docs/media/demo.mp4) and the README GIF
# (docs/media/demo.gif) from three iOS Simulator recordings in docs/media/raw:
#   prediction.mp4  typing "Running late for the meeting" mostly from predictions
#   cursor.mp4      holding space and gliding the caret across a paragraph
#   polish.mp4      one tap of Polish on a messy dictated message
# Record them with `xcrun simctl io <device> recordVideo --codec=h264 <file>`.
#
#     docs/media/make-demo-video.sh
set -euo pipefail
cd "$(dirname "$0")"
raw=raw
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
font=/System/Library/Fonts/SFNS.ttf
background=0x0B0F0F
teal=0x2BB3A6
size=1080x1920

# A text card: a big title and an optional line under it.
card() {
  local out=$1 seconds=$2 title=$3 line=${4:-}
  printf '%s' "$title" > "$work/title.txt"
  printf '%s' "$line" > "$work/line.txt"
  ffmpeg -v error -y -f lavfi -i "color=c=$background:s=$size:d=$seconds:r=30" -vf "\
drawtext=fontfile=$font:textfile=$work/title.txt:fontcolor=white:fontsize=92:x=(w-text_w)/2:y=(h/2)-120,\
drawtext=fontfile=$font:textfile=$work/line.txt:fontcolor=$teal:fontsize=46:x=(w-text_w)/2:y=(h/2)+20" \
    -c:v libx264 -pix_fmt yuv420p "$out"
}

# A feature clip: trimmed, sped up, the phone scaled below a caption.
feature() {
  local out=$1 source=$2 start=$3 end=$4 speed=$5 caption=$6 note=$7
  printf '%s' "$caption" > "$work/caption.txt"
  printf '%s' "$note" > "$work/note.txt"
  ffmpeg -v error -y -ss "$start" -to "$end" -i "$raw/$source" -vf "\
setpts=PTS/$speed,fps=30,scale=-2:1560,pad=1080:1920:(ow-iw)/2:330:color=$background,\
drawtext=fontfile=$font:textfile=$work/caption.txt:fontcolor=white:fontsize=58:x=(w-text_w)/2:y=110,\
drawtext=fontfile=$font:textfile=$work/note.txt:fontcolor=$teal:fontsize=38:x=(w-text_w)/2:y=205" \
    -an -c:v libx264 -pix_fmt yuv420p "$out"
}

# Polish goes first: it's the part people haven't seen a keyboard do. No title
# card, and the waits between taps are sped up, so it's over in about 15 seconds.
feature "$work/1.mp4" polish.mp4 1.8 8.5 1 "Tap Polish" "Runs on the phone. No server."
feature "$work/2.mp4" cursor.mp4 5.5 11 1.5 "Hold space to move the cursor" "Up and down too."
feature "$work/3.mp4" prediction.mp4 6 41 5 "Its own word prediction" "Shown at 5x speed."
card "$work/4.mp4" 1.5 "Whisper Polish" "Free and open source"

printf "file '%s'\n" "$work"/{1,2,3,4}.mp4 > "$work/list.txt"
ffmpeg -v error -y -f concat -safe 0 -i "$work/list.txt" -c:v libx264 -crf 23 -pix_fmt yuv420p -movflags +faststart demo.mp4

# The README can't play video from the repo, so it shows a GIF.
ffmpeg -v error -y -i demo.mp4 -vf "fps=12,scale=360:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" demo.gif
ls -la demo.mp4 demo.gif
