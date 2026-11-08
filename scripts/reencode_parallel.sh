#!/usr/bin/env bash
# v8 fast: xargs をやめた堅い並列版。& + wait -n で制御、失敗したら即分かる
set -euo pipefail
INPUT="$1"; OUTPUT="$2"; CODEC="${3:-hevc}"; CRF="${4:-22}"; PRESET="${5:-slow}"; PARALLEL="${6:-auto}"; CHUNK_SEC="${7:-600}"
EXT="${OUTPUT##*.}"; EXT=$(echo "$EXT" | tr 'A-Z' 'a-z')
echo "Parallel v9 (audio copy): $INPUT -> $OUTPUT codec=$CODEC crf=$CRF preset=$PRESET parallel=$PARALLEL chunk=${CHUNK_SEC}s ext=$EXT"
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | cut -d. -f1)
if [ -z "$DURATION" ] || [ "$DURATION" = "N/A" ]; then DURATION=0; fi
echo "Duration: ${DURATION}s"
NPROC=$(nproc)
if [ "$PARALLEL" = "auto" ]; then
  if [ "$NPROC" -le 4 ]; then WANT=4; elif [ "$NPROC" -le 8 ]; then WANT=6; else WANT=8; fi
else WANT="$PARALLEL"; fi
echo "WANT parallel: $WANT (CPU $NPROC)"
if [ "$DURATION" -lt $((CHUNK_SEC * 2)) ] || [ "$WANT" -le 1 ]; then
  echo "Short video or WANT<=1 -> single encode (FAST fallback)"
  bash scripts/reencode.sh "$INPUT" "$OUTPUT" "$CODEC" "$CRF" "$PRESET"
  exit 0
fi
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/enc"
echo "Workdir: $WORKDIR"
python3 scripts/make_chunks.py "$INPUT" "$CHUNK_SEC" > "$WORKDIR/chunks.tsv"
echo "--- chunks.tsv ---"
cat "$WORKDIR/chunks.tsv"
NUM=$(wc -l < "$WORKDIR/chunks.tsv")
echo "Chunks: $NUM (boundaries = original keyframes)"
if [ "$NUM" -le 1 ]; then
  echo "Only 1 chunk -> single"
  bash scripts/reencode.sh "$INPUT" "$OUTPUT" "$CODEC" "$CRF" "$PRESET"
  exit 0
fi
# --- 1チャンクをエンコードする関数 (中間は常にMKV、音声はOpus copy) ---
encode_one() {
  local idx="$1" start="$2" dur="$3" force="$4"
  local out="$WORKDIR/enc/chunk_${idx}.mkv"
  echo "[chunk $idx START] start=$start dur=$dur"
  if [ "$CODEC" = "hevc" ]; then
    ffmpeg -y -v error -hwaccel auto -threads 0 -ss "$start" -i "$INPUT" -t "$dur" -map 0:v:0 -map 0:a? -map 0:s? -dn -g 10000 -keyint_min 10000 -sc_threshold 0 -force_key_frames "$force" -c:v libx265 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p10le -x265-params "log-level=error:keyint=10000:min-keyint=10000:scenecut=0:open-gop=0" -c:a copy -c:s copy "$out"
  elif [ "$CODEC" = "av1" ]; then
    case "$PRESET" in ultrafast|veryfast) SVT=10;; fast) SVT=8;; medium) SVT=6;; slow) SVT=4;; veryslow) SVT=2;; *) SVT=6;; esac
    ffmpeg -y -v error -hwaccel auto -threads 0 -ss "$start" -i "$INPUT" -t "$dur" -map 0:v:0 -map 0:a? -map 0:s? -dn -g 10000 -keyint_min 10000 -sc_threshold 0 -force_key_frames "$force" -c:v libsvtav1 -preset "$SVT" -crf "$CRF" -pix_fmt yuv420p10le -svtav1-params "keyint=10000:scm=0" -c:a copy -c:s copy "$out"
  else
    ffmpeg -y -v error -hwaccel auto -threads 0 -ss "$start" -i "$INPUT" -t "$dur" -map 0:v:0 -map 0:a? -map 0:s? -dn -g 10000 -keyint_min 10000 -sc_threshold 0 -force_key_frames "$force" -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -profile:v high -c:a copy -c:s copy "$out"
  fi
  echo "[chunk $idx DONE] $out"
}
# --- 並列実行: & + wait -n (xargsの引用符バグなし) ---
FAIL=0
IDX=0
while IFS=$'\t' read -r start dur force; do
  # 空行は無視
  [ -z "$start" ] && continue
  IDX_FMT=$(printf "%03d" "$IDX")
  encode_one "$IDX_FMT" "$start" "$dur" "$force" &
  # 並列数を守る: WANT個走っていたら1個終わるまで待つ
  while [ "$(jobs -r -p | wc -l)" -ge "$WANT" ]; do
    if ! wait -n; then FAIL=1; echo "ERROR: a chunk failed" >&2; fi
  done
  IDX=$((IDX+1))
done < "$WORKDIR/chunks.tsv"
# 残りを全部待つ
while [ "$(jobs -r -p | wc -l)" -gt 0 ]; do
  if ! wait -n; then FAIL=1; echo "ERROR: a chunk failed" >&2; fi
done
if [ "$FAIL" -ne 0 ]; then
  echo "Parallel failed -> fallback single" >&2
  bash scripts/reencode.sh "$INPUT" "$OUTPUT" "$CODEC" "$CRF" "$PRESET"
  exit 0
fi
echo "All chunks done, files:"
ls -lh "$WORKDIR/enc/"
> "$WORKDIR/concat.txt"
for f in "$WORKDIR"/enc/chunk_*.mkv; do echo "file '$f'" >> "$WORKDIR/concat.txt"; done
cat "$WORKDIR/concat.txt"
if [ "$EXT" = "mkv" ]; then
  echo "Final MKV: concat + fonts from original"
  ffmpeg -y -v error -f concat -safe 0 -i "$WORKDIR/concat.txt" -i "$INPUT" -map 0:v -map 0:a? -map 0:s? -map 1:t? -c:v copy -c:a copy -c:s copy -c:t copy "$WORKDIR/final.mkv"
  mv "$WORKDIR/final.mkv" "$OUTPUT"
else
  echo "Final MP4: ASS->mov_text, audio copy (そのまま)"
  ffmpeg -y -v error -f concat -safe 0 -i "$WORKDIR/concat.txt" -map 0:v -map 0:a? -map 0:s? -dn -c:v copy -c:a copy -c:s mov_text -movflags +faststart "$OUTPUT"
fi
echo "Done parallel v9 (audio copy): $OUTPUT"
ls -lh "$OUTPUT"
ORIG_KF=$(timeout 60 ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$INPUT" | grep -c "K" || true)
NEW_KF=$(timeout 60 ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$OUTPUT" | grep -c "K" || true)
echo "Keyframes orig=$ORIG_KF new=$NEW_KF (should be equal)"
