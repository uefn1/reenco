#!/usr/bin/env python3
# 元のキーフレーム位置でチャンクを切る。チャンク境界 = 元のキーフレーム位置なので余分なキーフレームが出ない
# 使い方: python3 make_chunks.py <input> <chunk_seconds>
# 出力 (TSV): start<TAB>dur<TAB>force_list
import subprocess, json, sys
inp = sys.argv[1]
chunk_sec = float(sys.argv[2]) if len(sys.argv) > 2 else 600

# 全キーフレーム時刻
cmd = ["ffprobe","-v","error","-select_streams","v:0","-show_entries","frame=key_frame,pts_time,best_effort_timestamp_time","-of","json", inp]
out = subprocess.check_output(cmd, text=True)
frames = json.loads(out).get("frames", [])
kfs = []
for f in frames:
    if f.get("key_frame") != 1:
        continue
    t = f.get("pts_time") or f.get("best_effort_timestamp_time")
    if t is None:
        continue
    kfs.append(float(t))
kfs = sorted(set(kfs))
if not kfs or kfs[0] != 0:
    kfs = [0] + kfs

# duration
cmd2 = ["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0", inp]
try:
    dur = float(subprocess.check_output(cmd2, text=True).strip())
except:
    dur = kfs[-1] + chunk_sec

# チャンク分割: chunk_sec 以上になったら、次のキーフレームで切る
chunks = []
start_idx = 0
start_time = kfs[0]
for i in range(1, len(kfs)):
    if kfs[i] - start_time >= chunk_sec:
        # ここで切る
        end_time = kfs[i]
        # このチャンク内の相対キーフレーム
        rel = [round(t - start_time, 3) for t in kfs[start_idx:i]]
        if not rel or rel[0] != 0:
            rel = [0] + rel
        chunks.append((start_time, end_time - start_time, ",".join(f"{x:.3f}" for x in rel)))
        start_idx = i
        start_time = kfs[i]
# 最後
end_time = dur
rel = [round(t - start_time, 3) for t in kfs[start_idx:]]
if not rel or rel[0] != 0:
    rel = [0] + rel
chunks.append((start_time, end_time - start_time, ",".join(f"{x:.3f}" for x in rel)))

for s, d, force in chunks:
    # force が空なら 0 だけ
    if not force:
        force = "0.000"
    print(f"{s:.3f}\t{d:.3f}\t{force}")
