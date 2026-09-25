#!/usr/bin/env bash
# 本番のフィードを比較用コーパスとして手元に保存する (gitignore 下。コミットしない)。
# 使い方: fetcher/scripts/collect_corpus.sh urls.txt
#   urls.txt は1行1フィードURL。
set -euo pipefail

list="$1"
dir="$(cd "$(dirname "$0")/.." && pwd)/testdata/corpus"
mkdir -p "$dir"

n=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  n=$((n + 1))
  name=$(printf "feed%03d" "$n")
  if curl -fsSL --max-time 30 -A "Faraday v2.14.3" -o "$dir/$name.xml" "$url"; then
    printf '%s\n' "$url" > "$dir/$name.url"
    echo "ok   $name $url"
  else
    rm -f "$dir/$name.xml"
    echo "fail $name $url"
  fi
  sleep 1
done < "$list"
