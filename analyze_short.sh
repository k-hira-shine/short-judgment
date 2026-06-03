#!/usr/bin/env bash
# ショート動画から採点用の素材（メタ情報・品質チェック・文字起こし・静止画）を一括抽出する。
# 出力をAI採点プロンプト（ショート動画採点基準.md の section 8）に渡して採点する。
#
# 使い方:
#   ./analyze_short.sh <動画ファイル.mp4> [出力フォルダ] [whisperモデル]
# 例:
#   ./analyze_short.sh /path/to/動画.mp4
#   ./analyze_short.sh /path/to/動画.mp4 ./analysis medium
#
# 前提: ffmpeg / ffprobe / whisper がインストール済み（手順は 動画採点の手順.md を参照）

set -euo pipefail

VIDEO="${1:-}"
if [[ -z "$VIDEO" || ! -f "$VIDEO" ]]; then
  echo "エラー: 動画ファイルを指定してください。" >&2
  echo "使い方: $0 <動画ファイル.mp4> [出力フォルダ] [whisperモデル]" >&2
  exit 1
fi

# 必要コマンドの確認
for cmd in ffmpeg ffprobe whisper; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: $cmd が見つかりません。動画採点の手順.md のインストール手順を参照。" >&2
    exit 1
  fi
done

BASE_OUT="${2:-./analysis}"
MODEL="${3:-small}"
NAME="$(basename "$VIDEO")"
NAME="${NAME%.*}"
OUT="$BASE_OUT/$NAME"
FRAMES="$OUT/frames"
INFO="$OUT/info.txt"
mkdir -p "$FRAMES"

echo "出力先: $OUT"

# 1. 基本メタ情報
{
  echo "=== 基本情報 ==="
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,codec_name,avg_frame_rate \
    -of default=noprint_wrappers=1 "$VIDEO"
  ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,channels,sample_rate \
    -of default=noprint_wrappers=1 "$VIDEO"
  ffprobe -v error -show_entries format=duration,bit_rate \
    -of default=noprint_wrappers=1 "$VIDEO"
} > "$INFO"

# 動画の長さ（秒・整数）
DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" | cut -d. -f1)"
DUR="${DUR:-0}"

# 2. 品質チェック（黒フレーム・無音・音量）
{
  echo ""
  echo "=== 黒フレーム検出(0.1秒以上) ==="
  ffmpeg -i "$VIDEO" -vf "blackdetect=d=0.5:pic_th=0.98" -an -f null - 2>&1 \
    | grep -i blackdetect || echo "黒フレームなし（0.5秒未満はカット転換とみなし無視）"
  echo ""
  echo "=== 無音検出(-30dB, 0.5秒以上) ==="
  ffmpeg -i "$VIDEO" -af silencedetect=noise=-30dB:d=0.5 -f null - 2>&1 \
    | grep -i silence || echo "顕著な無音区間なし"
  echo ""
  echo "=== 音量(平均/最大) ==="
  ffmpeg -i "$VIDEO" -af volumedetect -f null - 2>&1 \
    | grep -iE "mean_volume|max_volume"
} >> "$INFO"

# 3. 静止画抽出（冒頭は密に、その後は3秒ごと）
echo "静止画を抽出中..."
for t in 0.3 1 2 3; do
  ffmpeg -y -ss "$t" -i "$VIDEO" -frames:v 1 "$FRAMES/t_${t}.jpg" -loglevel error || true
done
t=6
while [ "$t" -lt "$DUR" ]; do
  ffmpeg -y -ss "$t" -i "$VIDEO" -frames:v 1 "$FRAMES/t_${t}.jpg" -loglevel error || true
  t=$((t+3))
done
# 末尾フレーム
if [ "$DUR" -gt 1 ]; then
  ffmpeg -y -ss "$((DUR-1))" -i "$VIDEO" -frames:v 1 "$FRAMES/t_end.jpg" -loglevel error || true
fi

# 4. 文字起こし（ローカルWhisper・無料）
echo "文字起こし中（モデル: ${MODEL}）..."
whisper "$VIDEO" --language Japanese --model "$MODEL" \
  --output_format txt --output_dir "$OUT" --verbose False >/dev/null 2>&1 || {
  echo "警告: 文字起こしに失敗しました。モデルやファイルを確認してください。" >&2
}
# 文字起こしファイル名を統一
if [ -f "$OUT/$NAME.txt" ]; then
  mv -f "$OUT/$NAME.txt" "$OUT/transcript.txt"
fi

echo ""
echo "完了。次の素材を採点プロンプトに渡してください:"
echo "  - メタ情報/品質  : $INFO"
echo "  - 文字起こし      : $OUT/transcript.txt"
echo "  - 静止画(テロップ): $FRAMES/"
