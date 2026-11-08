#!/usr/bin/env bash
set -euo pipefail
INPUT="$1"; OUTPUT="$2"; CODEC="${3:-hevc}"; CRF="${4:-22}"; PRESET="${5:-slow}"
NPROC=$(nproc)
EXT="${OUTPUT##*.}"; EXT=$(echo "$EXT" | tr 'A-Z' 'a-z')
echo "Input:$INPUT Output:$OUTPUT Codec:$CODEC CRF:$CRF Preset:$PRESET CPU:$NPROC Ext:$EXT"
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
# 出力拡張子で分岐
# mkv: ASSそのまま + フォント添付も残す、faststartなし、tagなし
# mp4/mov: ASS->mov_text、添付は捨てる、faststartあり、hevcはhvc1
if [ "$EXT" = "mkv" ]; then
  SUB_CODEC="copy"
  ATTACH_MAP="-map 0:t?"
  ATTACH_CODEC="-c:t copy"
  MOVFLAGS=""
  TAG_OPT=""
  DROP_OPT=""
else
  SUB_CODEC="mov_text"
  ATTACH_MAP=""
  ATTACH_CODEC=""
  MOVFLAGS="-movflags +faststart"
  TAG_OPT="-tag:v hvc1"
  DROP_OPT="-dn"
fi
case "$CODEC" in
  hevc)
    if [ "$EXT" = "mkv" ]; then TAG_OPT=""; else TAG_OPT="-tag:v hvc1"; fi
    ffmpeg -y -hwaccel auto -threads 0 -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? $ATTACH_MAP -map_chapters 0 $DROP_OPT $GOP_OPT $FORCE_OPT -c:v libx265 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p10le $TAG_OPT -x265-params "log-level=error:pools=$NPROC:frame-threads=$NPROC:$X265_EXTRA" -c:a aac -b:a 160k -ac 2 -c:s $SUB_CODEC $ATTACH_CODEC $MOVFLAGS "$OUTPUT"
    ;;
  av1)
    case "$PRESET" in ultrafast|veryfast) SVT=10;; fast) SVT=8;; medium) SVT=6;; slow) SVT=4;; veryslow) SVT=2;; *) SVT=6;; esac
    ffmpeg -y -hwaccel auto -threads 0 -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? $ATTACH_MAP -map_chapters 0 $DROP_OPT $GOP_OPT $FORCE_OPT -c:v libsvtav1 -preset "$SVT" -crf "$CRF" -pix_fmt yuv420p10le -svtav1-params "keyint=10000:scm=0" -c:a aac -b:a 160k -ac 2 -c:s $SUB_CODEC $ATTACH_CODEC $MOVFLAGS "$OUTPUT"
    ;;
  h264)
    ffmpeg -y -hwaccel auto -threads 0 -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? $ATTACH_MAP -map_chapters 0 $DROP_OPT $GOP_OPT $FORCE_OPT -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -profile:v high -threads 0 -c:a aac -b:a 160k -ac 2 -c:s $SUB_CODEC $ATTACH_CODEC $MOVFLAGS "$OUTPUT"
    ;;
  copy)
    if [ "$EXT" = "mkv" ]; then
      echo "COPY mode mkv: 全部コピー (ASS+フォントも残る)"
      ffmpeg -y -i "$INPUT" -map 0 -c copy "$OUTPUT"
    else
      echo "COPY mode mp4: video/audio copy, subtitle ASS->mov_text, attachments dropped"
      ffmpeg -y -i "$INPUT" -map 0:v:0 -map 0:a? -map 0:s? -map_chapters 0 -dn -c:v copy -c:a copy -c:s mov_text -movflags +faststart "$OUTPUT"
    fi
    ;;
  *) echo "Unknown codec $CODEC" >&2; exit 1;;
esac
ls -lh "$OUTPUT"
