#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
Usage:
  postgres_daily_compare.sh
  postgres_daily_compare.sh <report_dir>
  postgres_daily_compare.sh <old_report_file> <new_report_file> [output_file]

Example:
  ./postgres_daily_compare.sh

  ./postgres_daily_compare.sh /home/postgres/postgres_daily_reports

  ./postgres_daily_compare.sh \
    /home/postgres/postgres_daily_reports/postgres_daily_check_db_20260706.log \
    /home/postgres/postgres_daily_reports/postgres_daily_check_db_20260707.log

Notes:
  - Sections 00, 01, and 02 are excluded.
  - Sections 03 and later are compared with unified diff.
USAGE
}

DEFAULT_REPORT_DIR="$HOME/postgres_daily_reports"

choose_report_file() {
  local report_dir="$1"
  local prompt="$2"
  local files=()
  local input=""
  local i=0

  if [ ! -d "$report_dir" ]; then
    echo "Report directory not found: $report_dir" >&2
    exit 1
  fi

  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$report_dir" -maxdepth 1 -type f -name 'postgres_daily_check_*.log' | sort -r)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No daily check report files found in: $report_dir" >&2
    exit 1
  fi

  echo >&2
  echo "$prompt" >&2
  echo "Report directory: $report_dir" >&2
  for i in "${!files[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "$(basename "${files[$i]}")" >&2
  done

  while true; do
    printf 'Select number: ' >&2
    read -r input

    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#files[@]}" ]; then
      printf '%s\n' "${files[$((input - 1))]}"
      return 0
    fi

    echo "Invalid selection: $input" >&2
  done
}

if [ "$#" -gt 3 ]; then
  usage >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  REPORT_DIR="$DEFAULT_REPORT_DIR"
  OLD_REPORT="$(choose_report_file "$REPORT_DIR" "Choose old report")"
  NEW_REPORT="$(choose_report_file "$REPORT_DIR" "Choose new report")"
  OUTPUT_FILE=""
elif [ "$#" -eq 1 ]; then
  if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
  fi
  REPORT_DIR="$1"
  OLD_REPORT="$(choose_report_file "$REPORT_DIR" "Choose old report")"
  NEW_REPORT="$(choose_report_file "$REPORT_DIR" "Choose new report")"
  OUTPUT_FILE=""
else
  OLD_REPORT="$1"
  NEW_REPORT="$2"
  OUTPUT_FILE="${3:-}"
fi

if [ ! -f "$OLD_REPORT" ]; then
  echo "Old report file not found: $OLD_REPORT" >&2
  exit 1
fi

if [ ! -f "$NEW_REPORT" ]; then
  echo "New report file not found: $NEW_REPORT" >&2
  exit 1
fi

if ! command -v diff >/dev/null 2>&1; then
  echo "diff command not found" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OLD_DIR="$TMP_DIR/old"
NEW_DIR="$TMP_DIR/new"
mkdir -p "$OLD_DIR" "$NEW_DIR"

sanitize_title() {
  sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+//; s/_+$//'
}

extract_sections() {
  local report_file="$1"
  local output_dir="$2"

  awk -v outdir="$output_dir" '
    /^[0-9][0-9]\. / {
      section_no = substr($0, 1, 2) + 0
      keep = section_no >= 3
      if (keep) {
        title = $0
        gsub(/[^A-Za-z0-9._-]+/, "_", title)
        gsub(/^_+|_+$/, "", title)
        file = outdir "/" sprintf("%02d", section_no) "_" title ".section"
        print $0 > file
      } else {
        file = ""
      }
      next
    }
    keep && file != "" {
      print $0 > file
    }
  ' "$report_file"
}

write_report() {
  {
    echo "PostgreSQL Daily Check Compare"
    echo "old_report=$OLD_REPORT"
    echo "new_report=$NEW_REPORT"
    echo "excluded_sections=00,01,02"
    echo "compared_sections=03+"
    echo "compare_started_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo
  }
}

extract_sections "$OLD_REPORT" "$OLD_DIR"
extract_sections "$NEW_REPORT" "$NEW_DIR"

if [ -n "$OUTPUT_FILE" ]; then
  exec > "$OUTPUT_FILE"
fi

write_report

section_names="$TMP_DIR/section_names.txt"
{
  find "$OLD_DIR" -type f -name '*.section' -printf '%f\n' 2>/dev/null
  find "$NEW_DIR" -type f -name '*.section' -printf '%f\n' 2>/dev/null
} | sort -u > "$section_names"

if [ ! -s "$section_names" ]; then
  echo "No comparable sections found."
  exit 0
fi

while IFS= read -r section_file; do
  old_section="$OLD_DIR/$section_file"
  new_section="$NEW_DIR/$section_file"

  echo "================================================================================"
  echo "SECTION: $section_file"
  echo "================================================================================"

  if [ ! -f "$old_section" ]; then
    echo "Only exists in new report."
    echo
    cat "$new_section"
    echo
    continue
  fi

  if [ ! -f "$new_section" ]; then
    echo "Only exists in old report."
    echo
    cat "$old_section"
    echo
    continue
  fi

  if diff -u "$old_section" "$new_section"; then
    echo "NO_DIFF"
  fi

  echo
done < "$section_names"

echo "================================================================================"
echo "Compare Finished"
echo "================================================================================"
echo "compare_finished_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"

if [ -n "$OUTPUT_FILE" ]; then
  echo "$OUTPUT_FILE" >&2
fi
