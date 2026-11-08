#!/usr/bin/env python3
# 高速版: packet でキーフレームを取得してチャンク分割
import subprocess, json, sys
inp = sys.argv[1]
chunk_sec = float(sys.argv[2]) if len(sys.argv) > 2 else 600
cmd = ["ffprobe","-v","error","-select_streams","v:0","-show_entries","packet=pts_time,flags","-of","json", inp]
out = subprocess.check_output(cmd, text=True, timeout=120)
packets = json.loads(out).get("packets", [])
kfs = []
for p in packets:
    if "K" not in p.get("flags",""):
        continue
    t = p.get("pts_time")
    if t is None:
        continue
    kfs.append(float(t))
kfs = sorted(set(kfs))
if not kfs or kfs[0] != 0:
    kfs = [0] + kfs
cmd2 = ["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0", inp]
try:
    dur = float(subprocess.check_output(cmd2, text=True, timeout=30).strip())
except:
    dur = kfs[-1] + chunk_sec
chunks = []
start_idx = 0
start_time = kfs[0]
for i in range(1, len(kfs)):
    if kfs[i] - start_time >= chunk_sec:
        end_time = kfs[i]
        rel = [round(t - start_time, 3) for t in kfs[start_idx:i]]
        if not rel or rel[0] != 0:
            rel = [0] + rel
        chunks.append((start_time, end_time - start_time, ",".join(f"{x:.3f}" for x in rel)))
        start_idx = i
        start_time = kfs[i]
end_time = dur
rel = [round(t - start_time, 3) for t in kfs[start_idx:]]
if not rel or rel[0] != 0:
    rel = [0] + rel
chunks.append((start_time, end_time - start_time, ",".join(f"{x:.3f}" for x in rel)))
for s, d, force in chunks:
    if not force:
        force = "0.000"
    print(f"{s:.3f}\t{d:.3f}\t{force}")
