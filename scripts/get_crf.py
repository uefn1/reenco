#!/usr/bin/env python3
"""
元の動画の CRF を検出する
- x265 / x264 はエンコード設定をビットストリーム内に ASCII で埋め込む (例: "crf=23.0")
- ffprobe の tags にも残っていることがある
- 見つからなければ何も出さない (呼び出し側が既定値にフォールバック)
使い方: python3 get_crf.py <input> <codec>
出力: 検出されたCRF (整数、例: 23) だけを stdout に出す
"""
import sys, re, json, subprocess

def from_ffprobe_tags(inp):
    try:
        out = subprocess.check_output(
            ["ffprobe","-v","error","-show_entries","stream_tags","-of","json", inp],
            text=True, timeout=30)
        data = json.loads(out)
        for s in data.get("streams", []):
            tags = s.get("tags", {})
            for k, v in tags.items():
                if not isinstance(v, str):
                    continue
                m = re.search(r"crf[=:\s]+([0-9]+(?:\.[0-9]+)?)", v, re.I)
                if m:
                    return float(m.group(1))
                # x265 settings が1つのタグに入っている場合
                if "x265" in v.lower() or "x264" in v.lower():
                    m2 = re.search(r"crf=([0-9]+(?:\.[0-9]+)?)", v)
                    if m2:
                        return float(m2.group(1))
    except Exception:
        pass
    return None

def from_binary(inp):
    # 先頭 100MB だけ読んで crf= を探す (1.1G全体を読むと遅いので)
    # x265 の設定文字列は大体先頭近くか、SEI にある
    try:
        patterns = [
            re.compile(rb"crf=([0-9]+(?:\.[0-9]+)?)"),
            re.compile(rb"crf[\s:=]+([0-9]+(?:\.[0-9]+)?)"),
        ]
        with open(inp, "rb") as f:
            # 先頭 100MB を 4MB ずつ読む
            read = 0
            buf = b""
            while read < 100 * 1024 * 1024:
                chunk = f.read(4 * 1024 * 1024)
                if not chunk:
                    break
                read += len(chunk)
                buf += chunk
                # バッファが大きくなりすぎないよう、最後の 1MB だけ残す
                if len(buf) > 5 * 1024 * 1024:
                    buf = buf[-1024*1024:]
                for pat in patterns:
                    m = pat.search(buf)
                    if m:
                        try:
                            return float(m.group(1).decode())
                        except:
                            continue
            # 見つからなければ、末尾も軽く見る (MKV は末尾にタグがあることもある)
            try:
                f.seek(-5 * 1024 * 1024, 2)
                tail = f.read()
                for pat in patterns:
                    m = pat.search(tail)
                    if m:
                        return float(m.group(1).decode())
            except Exception:
                pass
    except Exception:
        pass
    return None

def main():
    if len(sys.argv) < 2:
        sys.exit(0)
    inp = sys.argv[1]
    codec = sys.argv[2] if len(sys.argv) > 2 else "hevc"
    crf = from_ffprobe_tags(inp)
    if crf is None:
        crf = from_binary(inp)
    if crf is None:
        # 検出できず -> 何も出さない
        sys.exit(0)
    # AV1 は CRF スケールが違う: x265 の crf をそのまま使うと小さすぎる
    # 元が AV1 で crf=30 なら 30、元が HEVC で crf=23 を AV1 に使うなら +8 する
    # ここでは検出値をそのまま返すのが原則。呼び出し側で codec が違う場合のみ調整するなら別途
    # 今回は検出値を丸めて返す
    # ただし AV1 出力で元が HEVC (crf 18-28) の場合は、知覚品質を合わせるため +8 する
    # 元の codec は ffprobe で確認する
    try:
        out = subprocess.check_output(
            ["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream=codec_name","-of","csv=p=0", inp],
            text=True, timeout=15).strip()
        src_codec = out.lower()
    except Exception:
        src_codec = ""
    if codec == "av1" and src_codec in ("hevc","h265","h264","avc"):
        # hevc/h264 の crf 23 -> av1 だと 31 くらいが同等
        crf = crf + 8
        if crf > 45:
            crf = 45
    # 範囲チェック
    if codec == "av1":
        if crf < 20 or crf > 45:
            sys.exit(0)
    else:
        if crf < 10 or crf > 35:
            sys.exit(0)
    # 整数化 (x265 は 23.0 のように小数で入っている)
    print(int(round(crf)), end="")

if __name__ == "__main__":
    main()
