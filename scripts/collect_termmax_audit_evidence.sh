#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${OUTPUT_DIR:-audit-evidence}"
PDF_DIR="$OUT_DIR/pdfs"
TXT_DIR="$OUT_DIR/text"
mkdir -p "$PDF_DIR" "$TXT_DIR"

BASE="https://raw.githubusercontent.com/term-structure/audits/main/TermMax"
FILES=(
  "TermMax-ABDK-audit-report-Phase1-v2.pdf"
  "TermMax-ABDK-audit-report-Phase2.pdf"
  "TermMax-ABDK-audit-report-Phase3-v2.pdf"
  "TermMax-ABDK-audit-report-TMX-v-1-0.pdf"
  "TermMax-Cantina-competition-20250320.pdf"
)

for file in "${FILES[@]}"; do
  echo "Downloading $file"
  curl --fail --location --retry 4 --retry-all-errors \
    "$BASE/$file" -o "$PDF_DIR/$file"
  pdfinfo "$PDF_DIR/$file" > "$TXT_DIR/${file%.pdf}.pdfinfo.txt"
  pdftotext -layout "$PDF_DIR/$file" "$TXT_DIR/${file%.pdf}.txt"
done

SUMMARY="$OUT_DIR/audit_duplicate_search.md"
{
  echo '# TermMax public audit duplicate search'
  echo
  echo '## Corpus'
  echo
  for file in "${FILES[@]}"; do
    bytes=$(stat -c '%s' "$PDF_DIR/$file")
    sha=$(sha256sum "$PDF_DIR/$file" | awk '{print $1}')
    pages=$(awk -F: '/^Pages:/ {gsub(/^[ \t]+/, "", $2); print $2}' "$TXT_DIR/${file%.pdf}.pdfinfo.txt")
    echo "- \`$file\`: $pages pages, $bytes bytes, SHA-256 \`$sha\`"
  done
  echo
  echo '## Exact keyword search'
  echo
  for term in 'withdrawFts' 'WithdrawFts' 'previewWithdraw' 'post-default' 'post default' 'physical delivery' 'bad debt' 'badDebtMapping' 'totalAssets' 'redeemOrder' 'TermMaxVaultV2' 'OrderManagerV2'; do
    echo "### \`$term\`"
    echo
    matches=0
    for txt in "$TXT_DIR"/*.txt; do
      [[ "$txt" == *.pdfinfo.txt ]] && continue
      if grep -in -m 20 -F "$term" "$txt" > /tmp/audit_matches.txt; then
        matches=1
        echo "**$(basename "$txt")**"
        echo '```text'
        cat /tmp/audit_matches.txt
        echo '```'
      fi
    done
    if [[ $matches -eq 0 ]]; then
      echo 'No exact matches.'
    fi
    echo
  done
  echo '## Cover, revision, and scope excerpts'
  echo
  for txt in "$TXT_DIR"/*.txt; do
    [[ "$txt" == *.pdfinfo.txt ]] && continue
    echo "### $(basename "$txt")"
    echo '```text'
    sed -n '1,180p' "$txt"
    echo '```'
    echo
  done
} > "$SUMMARY"

echo "Wrote $SUMMARY"
cat "$SUMMARY"
