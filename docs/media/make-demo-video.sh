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
  local out=$1 source=$2 start=$3 end=$4 speed=$5 number=$6 caption=$7 note=$8
  printf '%s' "$number  $caption" > "$work/caption.txt"
  printf '%s' "$note" > "$work/note.txt"
  ffmpeg -v error -y -ss "$start" -to "$end" -i "$raw/$source" -vf "\
setpts=PTS/$speed,fps=30,scale=-2:1560,pad=1080:1920:(ow-iw)/2:330:color=$background,\
drawtext=fontfile=$font:textfile=$work/caption.txt:fontcolor=white:fontsize=58:x=(w-text_w)/2:y=110,\
drawtext=fontfile=$font:textfile=$work/note.txt:fontcolor=$teal:fontsize=38:x=(w-text_w)/2:y=205" \
    -an -c:v libx264 -pix_fmt yuv420p "$out"
}

card "$work/1.mp4" 3 "Whisper Polish" "An iPhone keyboard with its own AI, on the phone"
feature "$work/2.mp4" prediction.mp4 5 41 2 "1" "Its own word prediction" "A model trained for this keyboard  ·  shown at 2× speed"
feature "$work/3.mp4" cursor.mp4 4.5 14.5 1 "2" "Hold space to move the cursor" "Up, down and across lines, with your text in view"
feature "$work/4.mp4" polish.mp4 2.5 15 1 "3" "Polish, in the keyboard" "A model we trained, running on the phone  ·  no server"
card "$work/5.mp4" 3.5 "Open source" "github.com/jonclegg/whisper-polish"

printf "file '%s'\n" "$work"/{1,2,3,4,5}.mp4 > "$work/list.txt"
ffmpeg -v error -y -f concat -safe 0 -i "$work/list.txt" -c:v libx264 -crf 23 -pix_fmt yuv420p -movflags +faststart demo.mp4

# The README can't play video from the repo, so it shows a GIF.
ffmpeg -v error -y -i demo.mp4 -vf "fps=12,scale=360:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" demo.gif
ls -la demo.mp4 demo.gif
