#!/usr/bin/env bash
set -euo pipefail
INPUT="$1"; OUTPUT="$2"; CODEC="${3:-hevc}"; CRF="${4:-22}"; PRESET="${5:-slow}"
NPROC=$(nproc)
echo "Input:$INPUT Output:$OUTPUT Codec:$CODEC CRF:$CRF Preset:$PRESET CPU:$NPROC"
FORCE=$(python3 scripts/get_keyframes.py "$INPUT" 0 999999 || echo "")
if [ -n "$FORCE" ]; then
  echo "Preserve keyframes: $(echo "$FORCE" | tr ',' '\n' | wc -l) keyframes"
  FORCE_OPT="-force_key_frames $FORCE"
  GOP_OPT="-g 10000 -keyint_min 10000 -sc_threshold 0"
  X265_EXTRA="keyint=10000:min-keyint=10000:scenecut=0:open-gop=0"
else
  echo "No keyframe info -> fallback fixed GOP 250"
  FORCE_OPT=""
  GOP_OPT="-g 250 -keyint_min 250 -sc_threshold 0"
  X265_EXTRA="keyint=250:min-keyint=250:scenecut=0:open-gop=0"
fi
case "$CODEC" in
  hevc)
    ffmpeg -y -hwaccel auto -threads 0 -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? -map_chapters 0 $GOP_OPT $FORCE_OPT -c:v libx265 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p10le -tag:v hvc1 -x265-params "log-level=error:pools=$NPROC:frame-threads=$NPROC:$X265_EXTRA" -c:a aac -b:a 160k -ac 2 -c:s copy -movflags +faststart "$OUTPUT"
    ;;
  av1)
    case "$PRESET" in ultrafast|veryfast) SVT=10;; fast) SVT=8;; medium) SVT=6;; slow) SVT=4;; veryslow) SVT=2;; *) SVT=6;; esac
    ffmpeg -y -hwaccel auto -threads 0 -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? -map_chapters 0 $GOP_OPT $FORCE_OPT -c:v libsvtav1 -preset "$SVT" -crf "$CRF" -pix_fmt yuv420p10le -svtav1-params "keyint=10000:scm=0" -c:a aac -b:a 160k -ac 2 -c:s copy -movflags +faststart "$OUTPUT"
    ;;
  h264)
    ffmpeg -y -hwaccel auto -threads 0 -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? -map_chapters 0 $GOP_OPT $FORCE_OPT -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -profile:v high -threads 0 -c:a aac -b:a 160k -ac 2 -c:s copy -movflags +faststart "$OUTPUT"
    ;;
  copy)
    ffmpeg -y -i "$INPUT" -map 0 -c copy -movflags +faststart "$OUTPUT"
    ;;
  *) echo "Unknown codec $CODEC" >&2; exit 1;;
esac
ls -lh "$OUTPUT"
