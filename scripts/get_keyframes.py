#!/usr/bin/env python3
# 元動画のキーフレーム時刻リストを出す
# 使い方: python3 get_keyframes.py <input> <start_sec> <end_sec>
# 出力: 0,2.001,4.503,... (チャンク内相対時刻、カンマ区切り)
import subprocess, json, sys
inp = sys.argv[1]
start = float(sys.argv[2]) if len(sys.argv) > 2 else 0
end = float(sys.argv[3]) if len(sys.argv) > 3 else 999999

# ffprobe で全フレームの key_frame と pts_time を取得
cmd = ["ffprobe","-v","error","-select_streams","v:0","-show_entries","frame=key_frame,pts_time,best_effort_timestamp_time","-of","json", inp]
try:
    out = subprocess.check_output(cmd, text=True)
    data = json.loads(out)
    frames = data.get("frames", [])
except Exception as e:
    print("", end="")
    sys.exit(0)

kfs = []
for f in frames:
    if f.get("key_frame") != 1:
        continue
    t = f.get("pts_time") or f.get("best_effort_timestamp_time")
    if t is None:
        continue
    t = float(t)
    if t < start - 0.001 or t > end + 0.001:
        continue
    rel = t - start
    if rel < 0:
        rel = 0
    # 0 を必ず含める
    kfs.append(round(rel, 3))

# 先頭が 0 でなければ 0 を追加 (チャンク先頭は必ずキーフレーム)
if not kfs or kfs[0] != 0:
    kfs = [0] + kfs
# 重複除去・ソート
kfs = sorted(set(kfs))
# ffmpeg の force_key_frames はカンマ区切り。数が多すぎる場合はそのまま返す (チャンク単位なら 300件程度)
print(",".join(f"{x:.3f}" for x in kfs), end="")
