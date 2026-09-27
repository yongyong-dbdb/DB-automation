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
  - Sections 00 and 01 are excluded.
  - Section 02 is compared, but recent occurrence timestamps are excluded.
  - Default output shows a compact change summary.
  - In terminal mode, the script asks whether to show unified diff details.
  - When output_file is used, set COMPARE_DETAIL=true to include details.
USAGE
}

DEFAULT_REPORT_DIR="$HOME/postgres_daily_reports"
COMPARE_DETAIL="${COMPARE_DETAIL:-false}"
ASK_DETAIL="${ASK_DETAIL:-true}"

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

extract_sections() {
  local report_file="$1"
  local output_dir="$2"

  awk -v outdir="$output_dir" '
    /^[0-9][0-9]\. / {
      section_no = substr($0, 1, 2) + 0
      keep = section_no >= 2
      skip_recent_log_times = 0
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
    keep && section_no == 2 && /^## Recent 5 Occurrences Per Message/ {
      skip_recent_log_times = 1
      print "## Recent 5 Occurrences Per Message skipped for compare" > file
      next
    }
    keep && section_no == 2 && skip_recent_log_times {
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
    echo "excluded_sections=00,01"
    echo "compared_sections=02+"
    echo "normalized=section_02_recent_occurrence_timestamps_skipped"
    echo "compare_detail=$COMPARE_DETAIL"
    echo "ask_detail=$ASK_DETAIL"
    echo "compare_started_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo
  }
}

diff_counts() {
  local old_section="$1"
  local new_section="$2"

  diff -u "$old_section" "$new_section" |
    awk '
      /^--- / || /^\+\+\+ / || /^@@ / { next }
      /^\+/ { added++ }
      /^-/ { removed++ }
      END {
        printf "+%d -%d", added + 0, removed + 0
      }
    '
}

section_label() {
  local section_file="$1"
  echo "$section_file" | sed -E 's/^[0-9][0-9]_//; s/\.section$//; s/_/ /g'
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

summary_file="$TMP_DIR/change_summary.txt"
detail_file="$TMP_DIR/change_detail.txt"
changed_count=0
no_diff_count=0

{
  echo "================================================================================"
  echo "Change Summary"
  echo "================================================================================"
  printf "%-55s %-14s %s\n" "title" "status" "changes"
} > "$summary_file"

while IFS= read -r section_file; do
  old_section="$OLD_DIR/$section_file"
  new_section="$NEW_DIR/$section_file"
  title="$(section_label "$section_file")"

  if [ ! -f "$old_section" ]; then
    changed_count=$((changed_count + 1))
    printf "%-55s %-14s %s\n" "$title" "NEW_ONLY" "all_new" >> "$summary_file"
    {
      echo "================================================================================"
      echo "SECTION: $section_file"
      echo "================================================================================"
      echo "Only exists in new report."
      echo
      cat "$new_section"
      echo
    } >> "$detail_file"
    continue
  fi

  if [ ! -f "$new_section" ]; then
    changed_count=$((changed_count + 1))
    printf "%-55s %-14s %s\n" "$title" "OLD_ONLY" "all_removed" >> "$summary_file"
    {
      echo "================================================================================"
      echo "SECTION: $section_file"
      echo "================================================================================"
      echo "Only exists in old report."
      echo
      cat "$old_section"
      echo
    } >> "$detail_file"
    continue
  fi

  if diff -q "$old_section" "$new_section" >/dev/null; then
    no_diff_count=$((no_diff_count + 1))
    printf "%-55s %-14s %s\n" "$title" "NO_DIFF" "-" >> "$summary_file"
  else
    changed_count=$((changed_count + 1))
    changes="$(diff_counts "$old_section" "$new_section")"
    printf "%-55s %-14s %s\n" "$title" "CHANGED" "$changes" >> "$summary_file"
    {
      echo "================================================================================"
      echo "SECTION: $section_file"
      echo "================================================================================"
      diff -u "$old_section" "$new_section"
      echo
    } >> "$detail_file"
  fi
done < "$section_names"

{
  echo
  echo "changed_sections=$changed_count"
  echo "no_diff_sections=$no_diff_count"
  echo
} >> "$summary_file"

cat "$summary_file"

if [ -z "$OUTPUT_FILE" ] && [ "$COMPARE_DETAIL" != "true" ] && [ "$ASK_DETAIL" = "true" ] && [ -t 0 ]; then
  printf "Show detailed unified diff? [y/N]: " >&2
  read -r detail_answer
  case "$detail_answer" in
    y|Y|yes|YES) COMPARE_DETAIL="true" ;;
  esac
fi

if [ "$COMPARE_DETAIL" = "true" ]; then
  echo "================================================================================"
  echo "Detailed Diff"
  echo "================================================================================"
  if [ -s "$detail_file" ]; then
    cat "$detail_file"
  else
    echo "NO_DIFF"
  fi
else
  if [ -n "$OUTPUT_FILE" ]; then
    echo "Detailed diff is hidden. Run with COMPARE_DETAIL=true to include unified diff."
  else
    echo "Detailed diff is hidden."
  fi
  echo
fi

echo "================================================================================"
echo "Compare Finished"
echo "================================================================================"
echo "compare_finished_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"

if [ -n "$OUTPUT_FILE" ]; then
  echo "$OUTPUT_FILE" >&2
fi
