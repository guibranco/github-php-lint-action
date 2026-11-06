#!/usr/bin/env bash
#
# PHP Lint - checks PHP files for syntax errors with `php -l`, in parallel.
#
# Configuration comes from environment variables (action.yml sets them from the
# action inputs, but the script also runs on its own, e.g. `scripts/php-lint.sh`):
#
#   INPUT_PATH              Files or directories to lint, relative to the working
#                           directory. Newline or comma separated. Default: .
#                           A file listed here is linted whatever its extension.
#   INPUT_EXCLUDE           Files, directories or wildcard patterns to skip.
#                           Newline or comma separated. Default: vendor, node_modules
#   INPUT_EXTENSIONS        File extensions to lint. Newline or comma separated.
#                           Default: php
#   INPUT_FAIL_ON_WARNINGS  true/false - fail when PHP reports warnings or
#                           deprecations while compiling a file. Default: false
#   INPUT_ANNOTATIONS       true/false - emit GitHub annotations for each problem.
#                           Default: true on GitHub Actions, false elsewhere
#
# Exit codes: 0 = no problems, 1 = lint problems found, 2 = usage/environment error.
#
# Written for bash 3.2+ and the find/sort/xargs shipped with GNU, BSD and BusyBox.

set -euo pipefail

# bash 5.2+ treats "&" in the replacement of ${var//pattern/replacement} as "the
# matched text" unless this is switched off; older versions do not know the option.
shopt -u patsub_replacement 2> /dev/null || true

readonly EXIT_LINT=1
readonly EXIT_USAGE=2

# Files handed to each `php -l` worker process, and the caps that keep the log,
# the annotations and the job summary readable on very noisy code bases.
readonly BATCH_SIZE=10
readonly MAX_ANNOTATIONS=50
readonly MAX_SUMMARY_ROWS=100
readonly MAX_MESSAGE_LENGTH=1000

# Settings that make `php -l` report the same way everywhere, whatever php.ini says:
# every diagnostic, once, as plain text on stdout, and never killed by memory_limit.
# Everything else (short_open_tag, loaded extensions, ...) comes from the active php.ini.
readonly PHP_FLAGS=(
  -d display_errors=1
  -d display_startup_errors=0
  -d log_errors=0
  -d error_reporting=-1
  -d html_errors=0
  -d memory_limit=-1
)

# "<Label>: <message> in <file> on line <n>", optionally prefixed with "PHP " (log format).
readonly DIAGNOSTIC_REGEX='^(PHP )?(Parse error|Fatal error|Recoverable fatal error|Catchable fatal error|Unknown error|Warning|Notice|Deprecated|Strict Standards): +(.*) on line ([0-9]+)$'

readonly TAB=$'\t'

# Xdebug slows every `php -l` down and can write connection notices; lint never needs it.
export XDEBUG_MODE=off

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

on_github_actions() {
  [[ ${GITHUB_ACTIONS:-} == true ]]
}

# Escapes the message part of a workflow command.
escape_data() {
  local s=$1 percent='%' cr=$'\r' lf=$'\n'
  s=${s//"$percent"/%25}
  s=${s//"$cr"/%0D}
  s=${s//"$lf"/%0A}
  printf '%s' "$s"
}

# Escapes a property value (file=, title=) of a workflow command.
escape_property() {
  local s colon=':' comma=','
  s=$(escape_data "$1")
  s=${s//"$colon"/%3A}
  s=${s//"$comma"/%2C}
  printf '%s' "$s"
}

# Escapes text for a Markdown table cell so that nothing in a file name or a PHP
# message is interpreted as Markdown or HTML.
escape_markdown() {
  local s=$1 out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      '&') out+='&amp;' ;;
      '<') out+='&lt;' ;;
      '>') out+='&gt;' ;;
      '|') out+='&#124;' ;;
      '`') out+='&#96;' ;;
      '*') out+='&#42;' ;;
      '_') out+='&#95;' ;;
      '[') out+='&#91;' ;;
      ']') out+='&#93;' ;;
      \\) out+='&#92;' ;;
      '~') out+='&#126;' ;;
      '$') out+='&#36;' ;;
      '@') out+='&#64;' ;;
      '#') out+='&#35;' ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# Replaces control characters (tabs, newlines, ...) with spaces, so that a value
# fits in one field of one line. Used for reporting only, never for file access.
flatten() {
  local s=$1
  s=${s//[[:cntrl:]]/ }
  printf '%s' "$s"
}

# plural <count> <singular> [<plural>] -> "1 file", "3 files"
plural() {
  local count=$1 singular=$2 many=${3:-${2}s}
  if [[ $count -eq 1 ]]; then
    printf '%s %s' "$count" "$singular"
  else
    printf '%s %s' "$count" "$many"
  fi
}

# Reports a usage/environment problem and stops with EXIT_USAGE. The message goes
# to stderr (GitHub reads workflow commands from both streams) so that it is not
# swallowed when this runs inside a command substitution.
die() {
  if on_github_actions; then
    printf '::error title=PHP Lint::%s\n' "$(escape_data "$1")" >&2
  else
    printf 'php-lint: %s\n' "$1" >&2
  fi
  exit "$EXIT_USAGE"
}

# Reads a boolean setting: parse_boolean <name> <value> <default>
parse_boolean() {
  local name=$1 value=$2 default=$3
  case $value in
    '') printf '%s' "$default" ;;
    true | True | TRUE | yes | Yes | YES | on | On | ON | 1) printf 'true' ;;
    false | False | FALSE | no | No | NO | off | Off | OFF | 0) printf 'false' ;;
    *) die "Invalid value '$value' for '$name': expected true or false." ;;
  esac
}

# Splits a newline- or comma-separated list into LIST_ITEMS, trimming blanks and
# dropping empty items.
LIST_ITEMS=()
split_list() {
  local raw=$1 item comma=',' lf=$'\n'
  LIST_ITEMS=()
  raw=${raw//"$comma"/"$lf"}
  while IFS= read -r item || [[ -n $item ]]; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ -n $item ]]; then
      LIST_ITEMS+=("$item")
    fi
  done <<< "$raw"
}

cpu_count() {
  local count
  count=$(nproc 2> /dev/null || getconf _NPROCESSORS_ONLN 2> /dev/null || echo 2)
  if [[ ! $count =~ ^[1-9][0-9]*$ ]]; then
    count=2
  fi
  printf '%s' "$count"
}

# ---------------------------------------------------------------------------
# Worker: lints the files given as arguments (run in parallel through xargs)
# ---------------------------------------------------------------------------

# Appends one record per problem to the results file of this process:
#   <path> TAB <line> TAB <error|warning> TAB <label> TAB <message>
# A line of 0 means that PHP did not report one.
report() {
  local path=$1 line=$2 severity=$3 label=$4 message=$5
  message=$(flatten "$message")
  if [[ ${#message} -gt $MAX_MESSAGE_LENGTH ]]; then
    message="${message:0:$MAX_MESSAGE_LENGTH}..."
  fi
  if [[ -z $message ]]; then
    message='unknown problem'
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$line" "$severity" "$label" "$message" >> "$RESULTS_FILE"
}

# Turns the output of one `php -l` run into records.
parse_php_output() {
  local file=$1 status=$2 output=$3
  local path line label rest number message severity
  local has_error=false first_unknown_line=''

  # A file name with a line break in it would split PHP's message over two lines.
  if [[ $file == *[[:cntrl:]]* ]]; then
    output=${output//"$file"/"$(flatten "$file")"}
    file=$(flatten "$file")
  fi
  path=${file#./}

  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ -z $line ]]; then
      continue
    fi
    if [[ $line =~ $DIAGNOSTIC_REGEX ]]; then
      label=${BASH_REMATCH[2]}
      rest=${BASH_REMATCH[3]}
      number=${BASH_REMATCH[4]}
      # $rest is "<message> in <file>": cut the file name PHP repeats off the end.
      if [[ $rest == *" in $file" ]]; then
        message=${rest%" in $file"}
      elif [[ $rest == *" in Unknown" && $number -eq 0 ]]; then
        # Start-up message from the PHP installation, not about this file: only
        # worth reporting if PHP then fails to lint the file at all.
        if [[ -z $first_unknown_line ]]; then
          first_unknown_line=$line
        fi
        continue
      elif [[ $rest == *" in "* ]]; then
        message=${rest% in *}
      else
        message=$rest
      fi
      # Messages can mention the file again ("previously declared in ..."): show
      # the same path there as everywhere else in the report.
      message=${message//"$file"/"$path"}
      if [[ $label == *error ]]; then
        severity=error
        has_error=true
      else
        severity=warning
      fi
      report "$path" "$number" "$severity" "$label" "$message"
    elif [[ -z $first_unknown_line && $line != "Errors parsing "* && $line != "No syntax errors detected in "* ]]; then
      first_unknown_line=$line
    fi
  done <<< "$output"

  # php -l failed without a diagnostic this script understands (unreadable file,
  # crashed interpreter, ...): still fail the file, with whatever PHP said.
  if [[ $status -ne 0 && $has_error == false ]]; then
    report "$path" 0 error 'Error' "${first_unknown_line:-php -l exited with status $status}"
  fi
}

lint_worker() {
  local file output status
  RESULTS_FILE="$PHP_LINT_RESULTS_DIR/$$.tsv"

  for file in "$@"; do
    status=0
    # The braces silence bash's own "ignored null byte" warning on odd PHP output.
    { output=$(php "${PHP_FLAGS[@]}" -l "$file" 2>&1) || status=$?; } 2> /dev/null
    if [[ $status -eq 0 && $output == "No syntax errors detected in $file" ]]; then
      continue
    fi
    parse_php_output "$file" "$status" "$output"
  done

  # Lets the main process verify that no file was silently skipped.
  printf '%s\n' "$#" >> "$PHP_LINT_RESULTS_DIR/$$.count"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local script_path php_version annotations fail_on_warnings
  local item root pattern extension
  local -a directories=() files=() prune=() names=()
  local workdir list_file sorted_file find_errors
  local total jobs processed count_file results_file
  local errors=0 warnings=0
  local path line severity label message location icon
  local exit_code=0

  # Absolute path of this script, for the workers: they start after a `cd`.
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  # -- PHP -----------------------------------------------------------------
  if ! command -v php > /dev/null 2>&1; then
    die "PHP was not found on PATH. Keep 'setup-php: true' or install PHP before this step."
  fi
  php_version=$(php -d display_errors=0 -d display_startup_errors=0 -d log_errors=0 -r 'echo PHP_VERSION;' 2> /dev/null) ||
    die "The 'php' executable on PATH could not be run."
  php_version=${php_version##*$'\n'}

  # -- Settings ------------------------------------------------------------
  if on_github_actions; then
    annotations=$(parse_boolean annotations "${INPUT_ANNOTATIONS:-}" true) || exit "$EXIT_USAGE"
  else
    annotations=$(parse_boolean annotations "${INPUT_ANNOTATIONS:-}" false) || exit "$EXIT_USAGE"
  fi
  fail_on_warnings=$(parse_boolean fail-on-warnings "${INPUT_FAIL_ON_WARNINGS:-}" false) || exit "$EXIT_USAGE"

  # Paths are resolved from the repository root, which is also what annotations need.
  if [[ -n ${GITHUB_WORKSPACE:-} && -d ${GITHUB_WORKSPACE:-} ]]; then
    cd "$GITHUB_WORKSPACE"
  fi

  split_list "${INPUT_PATH:-.}"
  if [[ ${#LIST_ITEMS[@]} -eq 0 ]]; then
    LIST_ITEMS=(.)
  fi
  for item in "${LIST_ITEMS[@]}"; do
    case $item in
      /* | . | ./*) root=$item ;;
      *) root="./$item" ;;
    esac
    while [[ ${#root} -gt 1 && $root == */ ]]; do
      root=${root%/}
    done
    if [[ -f $root ]]; then
      files+=("$root") # named explicitly: linted whatever its extension
    elif [[ -e $root ]]; then
      directories+=("$root")
    else
      die "Path '$item' does not exist (looked in $PWD). Did the job check out the repository?"
    fi
  done

  # Git metadata is never linted; everything else is up to 'exclude'.
  prune=(-name .git)
  split_list "${INPUT_EXCLUDE-vendor,node_modules}"
  for item in ${LIST_ITEMS[@]+"${LIST_ITEMS[@]}"}; do
    pattern=${item#./}
    while [[ ${#pattern} -gt 1 && $pattern == */ ]]; do
      pattern=${pattern%/}
    done
    if [[ -z $pattern || $pattern == / ]]; then
      continue
    fi
    if [[ $pattern == /* ]]; then
      prune+=(-o -path "$pattern")
    else
      # Matches the entry at the top of the tree and at any depth below it.
      prune+=(-o -path "./$pattern" -o -path "*/$pattern")
    fi
  done

  split_list "${INPUT_EXTENSIONS:-php}"
  if [[ ${#LIST_ITEMS[@]} -eq 0 ]]; then
    LIST_ITEMS=(php)
  fi
  for item in "${LIST_ITEMS[@]}"; do
    extension=${item#\*}
    extension=${extension#.}
    if [[ ! $extension =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      die "Invalid file extension '$item' in 'extensions'."
    fi
    if [[ ${#names[@]} -gt 0 ]]; then
      names+=(-o)
    fi
    names+=(-iname "*.$extension")
  done

  # -- Find the files ------------------------------------------------------
  workdir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/php-lint.XXXXXX") ||
    die "Could not create a temporary directory."
  # shellcheck disable=SC2064 # expand $workdir now: it is a local variable
  trap "rm -rf '$workdir'" EXIT
  list_file="$workdir/files"
  sorted_file="$workdir/problems.tsv"
  find_errors="$workdir/find-errors"
  export PHP_LINT_RESULTS_DIR="$workdir/results"
  mkdir "$PHP_LINT_RESULTS_DIR"

  # -H: a directory given in 'path' may be a symbolic link; links met while
  # walking the tree are not followed.
  if ! {
    if [[ ${#files[@]} -gt 0 ]]; then
      printf '%s\0' "${files[@]}"
    fi
    if [[ ${#directories[@]} -gt 0 ]]; then
      find -H "${directories[@]}" \( "${prune[@]}" \) -prune -o -type f \( "${names[@]}" \) -print0 2> "$find_errors"
    fi
  } | LC_ALL=C sort -z -u > "$list_file"; then
    die "Could not read everything under the given paths (add what should be skipped to 'exclude'): $(flatten "$(cat "$find_errors")")"
  fi
  total=$(tr -cd '\0' < "$list_file" | wc -c | tr -d '[:space:]')

  if [[ $total -eq 0 ]]; then
    die "No PHP files found to lint in '$(flatten "${INPUT_PATH:-.}")'. Check that the job checks out the repository before this step, and the 'path', 'exclude' and 'extensions' inputs."
  fi

  # -- Lint ----------------------------------------------------------------
  jobs=$(cpu_count)
  printf 'PHP %s - linting %s with %s\n' "$php_version" "$(plural "$total" file)" "$(plural "$jobs" 'parallel job')"

  if ! xargs -0 -n "$BATCH_SIZE" -P "$jobs" "$BASH" "$script_path" --worker < "$list_file"; then
    die "A lint worker stopped unexpectedly; the results would be incomplete."
  fi

  processed=0
  for count_file in "$PHP_LINT_RESULTS_DIR"/*.count; do
    [[ -e $count_file ]] || continue
    while IFS= read -r line; do
      processed=$((processed + line))
    done < "$count_file"
  done
  if [[ $processed -ne $total ]]; then
    die "Only $processed of $total files were linted; the results would be incomplete."
  fi

  # -- Collect the problems: errors first, then warnings, each sorted by path
  : > "$sorted_file"
  for results_file in "$PHP_LINT_RESULTS_DIR"/*.tsv; do
    [[ -e $results_file ]] || continue
    cat "$results_file" >> "$sorted_file.unsorted"
  done
  if [[ -e "$sorted_file.unsorted" ]]; then
    LC_ALL=C sort -t "$TAB" -k3,3 -k1,1 -k2,2n "$sorted_file.unsorted" | uniq > "$sorted_file"
  fi

  while IFS="$TAB" read -r path line severity label message; do
    if [[ $severity == error ]]; then
      errors=$((errors + 1))
    else
      warnings=$((warnings + 1))
    fi
  done < "$sorted_file"

  # -- Log -----------------------------------------------------------------
  if [[ $((errors + warnings)) -gt 0 ]]; then
    printf '\n'
    while IFS="$TAB" read -r path line severity label message; do
      location=$path
      if [[ $line -gt 0 ]]; then
        location="$path:$line"
      fi
      if [[ $severity == error ]]; then
        icon='✖'
      else
        icon='⚠'
      fi
      printf '  %s %s - %s: %s\n' "$icon" "$location" "$label" "$message"
    done < "$sorted_file"
    printf '\n'
  fi

  if [[ $errors -gt 0 ]]; then
    printf '❌ %s checked: %s, %s\n' "$(plural "$total" file)" "$(plural "$errors" error)" "$(plural "$warnings" warning)"
    exit_code=$EXIT_LINT
  elif [[ $warnings -gt 0 ]]; then
    printf '⚠️ %s checked: no syntax errors, %s\n' "$(plural "$total" file)" "$(plural "$warnings" warning)"
    if [[ $fail_on_warnings == true ]]; then
      printf "Failing because 'fail-on-warnings' is enabled.\n"
      exit_code=$EXIT_LINT
    fi
  else
    printf '✅ No syntax errors detected in %s\n' "$(plural "$total" file)"
  fi

  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    {
      printf 'php-version=%s\n' "$php_version"
      printf 'files-checked=%s\n' "$total"
      printf 'errors=%s\n' "$errors"
      printf 'warnings=%s\n' "$warnings"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ $annotations == true && $((errors + warnings)) -gt 0 ]]; then
    write_annotations "$sorted_file"
  fi
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    write_summary "$sorted_file" "$php_version" "$total" "$errors" "$warnings" >> "$GITHUB_STEP_SUMMARY"
  fi

  exit "$exit_code"
}

# Emits one GitHub annotation per problem, folded away in the log because every
# problem is already listed there in a more readable form.
write_annotations() {
  local records=$1
  local path line severity label message properties
  local error_count=0 warning_count=0

  printf '::group::Annotations\n'
  while IFS="$TAB" read -r path line severity label message; do
    if [[ $severity == error ]]; then
      error_count=$((error_count + 1))
      [[ $error_count -le $MAX_ANNOTATIONS ]] || continue
    else
      warning_count=$((warning_count + 1))
      [[ $warning_count -le $MAX_ANNOTATIONS ]] || continue
    fi
    properties="file=$(escape_property "$path")"
    if [[ $line -gt 0 ]]; then
      properties+=",line=$line"
    fi
    properties+=",title=$(escape_property "PHP $label")"
    printf '::%s %s::%s\n' "$severity" "$properties" "$(escape_data "$message")"
  done < "$records"
  printf '::endgroup::\n'
}

# Prints the job summary (Markdown).
write_summary() {
  local records=$1 php_version=$2 total=$3 errors=$4 warnings=$5
  local path line severity label message icon rows=0

  printf '### PHP Lint\n\n'
  if [[ $errors -gt 0 && $warnings -gt 0 ]]; then
    printf '❌ **%s** and %s in %s checked with PHP %s.\n' \
      "$(plural "$errors" 'syntax error')" "$(plural "$warnings" warning)" "$(plural "$total" file)" "$php_version"
  elif [[ $errors -gt 0 ]]; then
    printf '❌ **%s** in %s checked with PHP %s.\n' \
      "$(plural "$errors" 'syntax error')" "$(plural "$total" file)" "$php_version"
  elif [[ $warnings -gt 0 ]]; then
    printf '⚠️ **No syntax errors**, but %s in %s checked with PHP %s.\n' \
      "$(plural "$warnings" warning)" "$(plural "$total" file)" "$php_version"
  else
    printf '✅ **No syntax errors** in %s checked with PHP %s.\n' "$(plural "$total" file)" "$php_version"
    return
  fi

  printf '\n| | File | Line | Message |\n|:-:|:--|--:|:--|\n'
  while IFS="$TAB" read -r path line severity label message; do
    rows=$((rows + 1))
    if [[ $rows -gt $MAX_SUMMARY_ROWS ]]; then
      continue
    fi
    if [[ $severity == error ]]; then
      icon='❌'
    else
      icon='⚠️'
    fi
    if [[ $line -eq 0 ]]; then
      line=''
    fi
    printf '| %s | <code>%s</code> | %s | <strong>%s:</strong> %s |\n' \
      "$icon" "$(escape_markdown "$path")" "$line" "$(escape_markdown "$label")" "$(escape_markdown "$message")"
  done < "$records"
  if [[ $rows -gt $MAX_SUMMARY_ROWS ]]; then
    printf '\n_Showing the first %s of %s problems; the job log lists all of them._\n' "$MAX_SUMMARY_ROWS" "$rows"
  fi
}

if [[ ${1:-} == --worker ]]; then
  shift
  lint_worker "$@"
else
  main
fi
