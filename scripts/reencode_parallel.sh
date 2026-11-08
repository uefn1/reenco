#!/usr/bin/env bash
# 分割並列エンコード - キーフレーム増加なし版
# 原理: 1) チャンク境界を元のキーフレーム位置に合わせる 2) 各チャンク内は元のキーフレームだけを force_key_frames で強制 3) scenecut無効 + keyint大で自動挿入を防ぐ
# => 合計キーフレーム数 = 元のキーフレーム数 と一致する
set -euo pipefail
INPUT="$1"; OUTPUT="$2"; CODEC="${3:-hevc}"; CRF="${4:-22}"; PRESET="${5:-slow}"; PARALLEL="${6:-auto}"; CHUNK_SEC="${7:-600}"
echo "Parallel (no extra keyframes): $INPUT -> $OUTPUT codec=$CODEC crf=$CRF preset=$PRESET parallel=$PARALLEL chunk=${CHUNK_SEC}s"

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" | cut -d. -f1)
if [ -z "$DURATION" ] || [ "$DURATION" = "N/A" ]; then DURATION=0; fi
echo "Duration: ${DURATION}s"

NPROC=$(nproc)
if [ "$PARALLEL" = "auto" ]; then
  if [ "$NPROC" -le 4 ]; then WANT=4; elif [ "$NPROC" -le 8 ]; then WANT=6; else WANT=8; fi
else
  WANT="$PARALLEL"
fi

# 短い動画は1本にフォールバック
if [ "$DURATION" -lt $((CHUNK_SEC * 2)) ] || [ "$WANT" -le 1 ]; then
  echo "Short video -> single encode (same keyframe logic)"
  bash scripts/reencode.sh "$INPUT" "$OUTPUT" "$CODEC" "$CRF" "$PRESET"
  exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/enc"
echo "Workdir: $WORKDIR"

# 1. 元のキーフレーム位置でチャンク一覧を作る
python3 scripts/make_chunks.py "$INPUT" "$CHUNK_SEC" > "$WORKDIR/chunks.tsv"
cat "$WORKDIR/chunks.tsv"
NUM=$(wc -l < "$WORKDIR/chunks.tsv")
echo "Chunks: $NUM (boundaries = original keyframes)"
if [ "$NUM" -le 1 ]; then
  bash scripts/reencode.sh "$INPUT" "$OUTPUT" "$CODEC" "$CRF" "$PRESET"
  exit 0
fi

# 2. 各チャンクを並列エンコード
# チャンク開始は元のキーフレームなので -ss を入力前に置く高速シークでもフレームずれなし
encode_chunk() {
  local idx="$1" start="$2" dur="$3" force="$4"
  local out="$WORKDIR/enc/chunk_${idx}.mkv"
  echo "Chunk $idx: start=$start dur=$dur keyframes=$(echo "$force" | tr ',' '\n' | wc -l)"
  # GOP自動挿入を防ぐための固定設定
  if [ "$CODEC" = "hevc" ]; then
    ffmpeg -y -v error -hwaccel auto -threads 0 -ss "$start" -i "$INPUT" -t "$dur" -map 0:v:0 -map 0:a? -map 0:s? -g 10000 -keyint_min 10000 -sc_threshold 0 -force_key_frames "$force" -c:v libx265 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p10le -tag:v hvc1 -x265-params "log-level=error:keyint=10000:min-keyint=10000:scenecut=0:open-gop=0" -c:a aac -b:a 160k -ac 2 -c:s copy -movflags +faststart "$out"
  elif [ "$CODEC" = "av1" ]; then
    ffmpeg -y -v error -hwaccel auto -threads 0 -ss "$start" -i "$INPUT" -t "$dur" -map 0:v:0 -map 0:a? -map 0:s? -g 10000 -keyint_min 10000 -sc_threshold 0 -force_key_frames "$force" -c:v libsvtav1 -preset 4 -crf "$CRF" -pix_fmt yuv420p10le -svtav1-params "keyint=10000:scm=0" -c:a aac -b:a 160k -ac 2 -c:s copy -movflags +faststart "$out"
  else
    ffmpeg -y -v error -hwaccel auto -threads 0 -ss "$start" -i "$INPUT" -t "$dur" -map 0:v:0 -map 0:a? -map 0:s? -g 10000 -keyint_min 10000 -sc_threshold 0 -force_key_frames "$force" -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p -profile:v high -c:a aac -b:a 160k -ac 2 -c:s copy -movflags +faststart "$out"
  fi
}
export INPUT CODEC CRF PRESET WORKDIR
export -f encode_chunk

# TSV を並列実行用に変換: idx<TAB>start<TAB>dur<TAB>force
awk -F'\t' '{printf "%03d\t%s\t%s\t%s\n", NR-1, $1, $2, $3}' "$WORKDIR/chunks.tsv" > "$WORKDIR/jobs.tsv"
cat "$WORKDIR/jobs.tsv" | cut -f1-3
# force リストにタブ/スペースが入らないよう注意: force はカンマ区切りなのでそのまま渡せる
# xargs で並列: 1行ごとに encode_chunk を呼ぶ。force は 4列目
cat "$WORKDIR/jobs.tsv" | xargs -P "$WANT" -d '\n' -I {} bash -c 'IFS=$'"'"'\t'"'"' read -r idx start dur force <<< "{}"; encode_chunk "$idx" "$start" "$dur" "$force"' || {
  echo "Parallel failed -> fallback single" >&2
  bash scripts/reencode.sh "$INPUT" "$OUTPUT" "$CODEC" "$CRF" "$PRESET"
  exit 0
}
ls -lh "$WORKDIR/enc/"

# 3. 結合 (コピー、再エンコードなしなのでキーフレームは増えない)
> "$WORKDIR/concat.txt"
for f in "$WORKDIR"/enc/chunk_*.mkv; do echo "file '$f'" >> "$WORKDIR/concat.txt"; done
cat "$WORKDIR/concat.txt"
ffmpeg -y -v error -f concat -safe 0 -i "$WORKDIR/concat.txt" -c copy -movflags +faststart "$OUTPUT"
echo "Done parallel (no extra keyframes): $OUTPUT"
ls -lh "$OUTPUT"
ORIG_KF=$(ffprobe -v error -select_streams v:0 -show_entries frame=key_frame -of csv=p=0 "$INPUT" | grep -c "^1" || true)
NEW_KF=$(ffprobe -v error -select_streams v:0 -show_entries frame=key_frame -of csv=p=0 "$OUTPUT" | grep -c "^1" || true)
echo "Keyframes orig=$ORIG_KF new=$NEW_KF (should be equal)"
