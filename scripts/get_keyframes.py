#!/usr/bin/env python3
# 高速版: packet でキーフレームを取得 (frameだと全デコードで遅い)
import subprocess, json, sys
inp = sys.argv[1]
start = float(sys.argv[2]) if len(sys.argv) > 2 else 0
end = float(sys.argv[3]) if len(sys.argv) > 3 else 999999
cmd = ["ffprobe","-v","error","-select_streams","v:0","-show_entries","packet=pts_time,flags","-of","json", inp]
try:
    out = subprocess.check_output(cmd, text=True, timeout=120)
    data = json.loads(out)
    packets = data.get("packets", [])
except Exception:
    print("", end="")
    sys.exit(0)
kfs = []
for p in packets:
    flags = p.get("flags", "")
    if "K" not in flags:
        continue
    t = p.get("pts_time")
    if t is None:
        continue
    t = float(t)
    if t < start - 0.001 or t > end + 0.001:
        continue
    rel = t - start
    if rel < 0:
        rel = 0
    kfs.append(round(rel, 3))
if not kfs or kfs[0] != 0:
    kfs = [0] + kfs
kfs = sorted(set(kfs))
print(",".join(f"{x:.3f}" for x in kfs), end="")
