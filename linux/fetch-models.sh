#!/bin/bash
# Downloads the RapidOCR PP-OCRv6 "small" ONNX models (PaddleOCR, Apache-2.0) into linux/models/,
# checking their SHA-256. Needed before `cargo deb`; the release workflow runs it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/models"
BASE="https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6"
mkdir -p "$DIR"
fetch() {
    local url="$1" file="$2" sum="$3"
    if [[ -f "$DIR/$file" ]] && echo "$sum  $DIR/$file" | sha256sum -c --status; then
        echo "ok   $file"; return
    fi
    echo "get  $file"
    curl -fsSL --retry 3 -o "$DIR/$file.part" "$url"
    echo "$sum  $DIR/$file.part" | sha256sum -c --status || { echo "checksum mismatch: $file" >&2; exit 1; }
    mv "$DIR/$file.part" "$DIR/$file"
}
fetch "$BASE/det/PP-OCRv6_det_small.onnx" PP-OCRv6_det_small.onnx 090f04abcd9d9a7498bc4ebf677e4cb9bdce1fe4197ddb7e529f1ef44e1ff94f
fetch "$BASE/rec/PP-OCRv6_rec_small.onnx" PP-OCRv6_rec_small.onnx 6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884
[[ -f "$DIR/LICENSE-PaddleOCR.txt" ]] || curl -fsSL --retry 3 -o "$DIR/LICENSE-PaddleOCR.txt" \
    https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/main/LICENSE
echo "models in $DIR"
