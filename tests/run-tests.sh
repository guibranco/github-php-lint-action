#!/usr/bin/env bash
#
# Test suite for scripts/php-lint.sh. It runs against the php executable on PATH,
# so run it once per PHP version you care about:
#
#   tests/run-tests.sh              # every test
#   tests/run-tests.sh exclude      # only the tests whose name contains "exclude"
#
# Each test gets an empty sandbox directory ($SANDBOX) to fill with files, runs
# the lint script in it with `lint NAME=value ...` and checks $STATUS, $OUTPUT,
# the job summary and the step outputs.

# The tests deliberately keep "$(...)", backticks and "$variables" unexpanded in
# file names and in the scripts they generate.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly LINT="$ROOT/scripts/php-lint.sh"

REAL_PHP="$(command -v php || true)"
if [[ -z $REAL_PHP ]]; then
  echo "tests: php was not found on PATH" >&2
  exit 2
fi
readonly REAL_PHP
PHP_VERSION="$(php -r 'echo PHP_VERSION;')"
PHP_VERSION_ID="$(php -r 'echo PHP_VERSION_ID;')"
readonly PHP_VERSION PHP_VERSION_ID

WORK="$(mktemp -d "${TMPDIR:-/tmp}/php-lint-tests.XXXXXX")"
readonly WORK
trap 'chmod -R u+rwx "$WORK" 2> /dev/null; rm -rf "$WORK"' EXIT

# Source code used by the tests. Each snippet behaves the same from PHP 5.6 on.
readonly VALID='<?php
echo "ok";'
readonly PARSE_ERROR='<?php
function broken( {
    return 1;
}'
readonly FATAL_ERROR='<?php
function twice() {}
function twice() {}'
readonly WARNING='<?php
declare(foo=1);
echo "ok";'
readonly DEPRECATED='<?php
function optional_first($a = 1, $b) { return $a + $b; }'

SANDBOX=''
META=''
STATUS=0
OUTPUT=''
FAILED=false
SKIPPED=''

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# put <path> <content>: writes a file below the sandbox, creating directories.
put() {
  local target="$SANDBOX/$1"
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$2" > "$target"
}

# lint [NAME=value ...]: runs the lint script in the sandbox. Nothing from the
# calling environment (for example the CI job running these tests) leaks in.
lint() {
  STATUS=0
  : > "$META/outputs"
  : > "$META/summary"
  OUTPUT="$(
    cd "$SANDBOX" || exit 99
    unset GITHUB_ACTIONS GITHUB_WORKSPACE RUNNER_TEMP
    unset INPUT_PATH INPUT_EXCLUDE INPUT_EXTENSIONS INPUT_FAIL_ON_WARNINGS INPUT_ANNOTATIONS INPUT_COMMENT
    unset PHP_LINT_REPORT_FILE
    export GITHUB_OUTPUT="$META/outputs" GITHUB_STEP_SUMMARY="$META/summary" TMPDIR="$META/tmp"
    for setting in "$@"; do
      export "${setting?}"
    done
    "$BASH" "$LINT" 2>&1
  )" || STATUS=$?
}

fail() {
  FAILED=true
  printf '    FAILED: %s\n' "$1"
}

assert_status() {
  if [[ $STATUS -ne $1 ]]; then
    fail "expected exit status $1, got $STATUS"
  fi
}

# assert_contains <text> <expected fragment> [<what the text is>]
assert_contains() {
  if [[ $1 != *"$2"* ]]; then
    fail "${3:-output} does not contain: $2"
  fi
}

assert_not_contains() {
  if [[ $1 == *"$2"* ]]; then
    fail "${3:-output} should not contain: $2"
  fi
}

assert_equals() {
  if [[ $1 != "$2" ]]; then
    fail "${3:-value}: expected '$2', got '$1'"
  fi
}

# assert_output <name> <value>: checks a step output written to $GITHUB_OUTPUT.
assert_output() {
  local actual
  actual="$(sed -n "s/^$1=//p" "$META/outputs")"
  assert_equals "$actual" "$2" "output '$1'"
}

summary() {
  cat "$META/summary"
}

skip() {
  SKIPPED=$1
}

run_test() {
  local name=$1
  SANDBOX="$WORK/$name/sandbox"
  META="$WORK/$name/meta"
  mkdir -p "$SANDBOX" "$META/tmp"
  STATUS=0
  OUTPUT=''
  FAILED=false
  SKIPPED=''

  "$name"

  if [[ -n $SKIPPED ]]; then
    printf 'skip  %s (%s)\n' "$name" "$SKIPPED"
    skipped_count=$((skipped_count + 1))
  elif [[ $FAILED == true ]]; then
    printf 'FAIL  %s\n' "$name"
    printf '    exit status: %s\n    output:\n' "$STATUS"
    printf '%s\n' "$OUTPUT" | sed 's/^/      | /'
    failed_count=$((failed_count + 1))
  else
    printf 'ok    %s\n' "$name"
    passed_count=$((passed_count + 1))
  fi
}

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

test_valid_files_pass() {
  put index.php "$VALID"
  put src/Deep/Nested/File.php "$VALID"
  lint
  assert_status 0
  assert_contains "$OUTPUT" "PHP $PHP_VERSION - linting 2 files"
  assert_contains "$OUTPUT" "No syntax errors detected in 2 files"
  assert_output files-checked 2
  assert_output errors 0
  assert_output warnings 0
  assert_output php-version "$PHP_VERSION"
}

test_parse_error_fails() {
  put index.php "$VALID"
  put src/broken.php "$PARSE_ERROR"
  lint
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/broken.php:2 - Parse error: syntax error"
  assert_contains "$OUTPUT" "2 files checked: 1 error, 0 warnings"
  assert_not_contains "$OUTPUT" "index.php"
  assert_output files-checked 2
  assert_output errors 1
  assert_output warnings 0
}

test_fatal_compile_error_fails() {
  put src/twice.php "$FATAL_ERROR"
  lint
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/twice.php:3 - Fatal error: Cannot redeclare"
  # PHP repeats the file name inside this message; it is shown like everywhere else.
  assert_contains "$OUTPUT" "(previously declared in src/twice.php:2)"
  # PHP 8.5+ appends a stack trace to fatal errors; it must not become a second problem.
  assert_output errors 1
}

test_warning_does_not_fail_by_default() {
  put src/odd.php "$WARNING"
  lint
  assert_status 0
  assert_contains "$OUTPUT" "⚠ src/odd.php:2 - Warning: Unsupported declare 'foo'"
  assert_contains "$OUTPUT" "1 file checked: no syntax errors, 1 warning"
  assert_output errors 0
  assert_output warnings 1
}

test_fail_on_warnings() {
  put src/odd.php "$WARNING"
  lint INPUT_FAIL_ON_WARNINGS=true
  assert_status 1
  assert_contains "$OUTPUT" "Failing because 'fail-on-warnings' is enabled."
  assert_output errors 0
  assert_output warnings 1

  lint INPUT_FAIL_ON_WARNINGS=false
  assert_status 0
}

test_deprecation_is_a_warning() {
  if [[ $PHP_VERSION_ID -lt 80000 ]]; then
    skip "PHP $PHP_VERSION has no compile-time deprecation for this code"
    return
  fi
  put src/old.php "$DEPRECATED"
  lint
  assert_status 0
  assert_contains "$OUTPUT" "⚠ src/old.php:2 - Deprecated: "
  assert_output warnings 1
}

test_errors_are_listed_before_warnings() {
  put a.php "$WARNING"
  put b.php "$PARSE_ERROR"
  put c.php "$WARNING"
  put d.php "$FATAL_ERROR"
  lint
  assert_status 1
  local problems
  problems="$(printf '%s\n' "$OUTPUT" | sed -n 's/^  [^ ]* \([a-z]\.php\):.*/\1/p' | tr '\n' ' ')"
  assert_equals "$problems" "b.php d.php a.php c.php " "order of the reported problems"
  assert_output errors 2
  assert_output warnings 2
}

test_many_files() {
  local i broken=0
  for i in $(seq 1 240); do
    if [[ $((i % 40)) -eq 0 ]]; then
      put "src/dir$((i % 7))/file$i.php" "$PARSE_ERROR"
      broken=$((broken + 1))
    else
      put "src/dir$((i % 7))/file$i.php" "$VALID"
    fi
  done
  lint
  assert_status 1
  assert_output files-checked 240
  assert_output errors "$broken"
  # Same input, same report: the workers finish in any order, the report is sorted.
  local first=$OUTPUT
  lint
  assert_equals "$OUTPUT" "$first" "output of a second run"
}

# ---------------------------------------------------------------------------
# Which files are linted
# ---------------------------------------------------------------------------

test_default_exclude_skips_vendor_and_node_modules() {
  put src/ok.php "$VALID"
  put vendor/lib/broken.php "$PARSE_ERROR"
  put src/vendor/lib/broken.php "$PARSE_ERROR"
  put node_modules/pkg/broken.php "$PARSE_ERROR"
  put .git/hooks/broken.php "$PARSE_ERROR"
  lint
  assert_status 0
  assert_output files-checked 1
}

test_exclude_replaces_the_default_list() {
  put src/ok.php "$VALID"
  put build/broken.php "$PARSE_ERROR"
  put vendor/lib/broken.php "$PARSE_ERROR"
  lint INPUT_EXCLUDE=build
  assert_status 1
  assert_contains "$OUTPUT" "✖ vendor/lib/broken.php:2"
  assert_not_contains "$OUTPUT" "build/broken.php"
  assert_output files-checked 2
}

test_empty_exclude_lints_everything() {
  put src/ok.php "$VALID"
  put vendor/lib/broken.php "$PARSE_ERROR"
  put .git/hooks/broken.php "$PARSE_ERROR"
  lint INPUT_EXCLUDE=
  assert_status 1
  assert_contains "$OUTPUT" "✖ vendor/lib/broken.php:2"
  # ...except Git's own directory, which is never linted.
  assert_output files-checked 2
}

test_exclude_patterns() {
  put src/ok.php "$VALID"
  put cache/broken.php "$PARSE_ERROR"                # directory at the top
  put src/module/cache/broken.php "$PARSE_ERROR"     # same name, deeper
  put tests/fixtures/broken.php "$PARSE_ERROR"       # nested directory path
  put src/legacy/old.php "$PARSE_ERROR"              # one specific file
  put src/models/User.generated.php "$PARSE_ERROR"   # wildcard
  put src/mycache/ok.php "$VALID"                    # only a similar name: still linted
  lint "INPUT_EXCLUDE=cache/
./tests/fixtures
src/legacy/old.php, *.generated.php"
  assert_status 0
  assert_output files-checked 2
}

test_extensions() {
  put index.php "$VALID"
  put shout.PHP "$PARSE_ERROR"
  put view.phtml "$PARSE_ERROR"
  put legacy.inc "$PARSE_ERROR"
  put notes.txt "$PARSE_ERROR"

  lint
  assert_status 1
  assert_contains "$OUTPUT" "✖ shout.PHP:2"
  assert_output files-checked 2

  lint "INPUT_EXTENSIONS=php, .phtml
*.inc"
  assert_status 1
  assert_contains "$OUTPUT" "✖ view.phtml:2"
  assert_contains "$OUTPUT" "✖ legacy.inc:2"
  assert_output files-checked 4
  assert_output errors 3

  lint INPUT_EXTENSIONS=phtml
  assert_output files-checked 1
}

test_invalid_extension_is_rejected() {
  put index.php "$VALID"
  lint "INPUT_EXTENSIONS=php,*"
  assert_status 2
  assert_contains "$OUTPUT" "Invalid file extension '*'"
}

test_path_limits_what_is_linted() {
  put src/ok.php "$VALID"
  put lib/ok.php "$VALID"
  put tools/broken.php "$PARSE_ERROR"

  lint INPUT_PATH=src
  assert_status 0
  assert_output files-checked 1

  lint "INPUT_PATH=src, lib"
  assert_status 0
  assert_output files-checked 2

  lint "INPUT_PATH=src
tools"
  assert_status 1
  assert_contains "$OUTPUT" "✖ tools/broken.php:2"
  assert_output files-checked 2
}

test_path_spelling_does_not_matter() {
  put src/broken.php "$PARSE_ERROR"
  local spelling
  for spelling in src src/ ./src ./src/ "$SANDBOX/src"; do
    lint "INPUT_PATH=$spelling"
    assert_status 1
    assert_output files-checked 1
  done
  lint INPUT_PATH=./src/
  assert_contains "$OUTPUT" "✖ src/broken.php:2"
}

test_path_can_be_a_single_file() {
  put src/ok.php "$VALID"
  put src/broken.php "$PARSE_ERROR"
  lint INPUT_PATH=src/ok.php
  assert_status 0
  assert_output files-checked 1
}

test_listed_file_is_linted_whatever_its_extension() {
  put src/ok.php "$VALID"
  put bin/console "$PARSE_ERROR"
  put artisan "$VALID"

  lint
  assert_status 0
  assert_output files-checked 1

  lint "INPUT_PATH=., bin/console, artisan"
  assert_status 1
  assert_contains "$OUTPUT" "✖ bin/console:2 - Parse error"
  assert_output files-checked 3

  # ...even when a pattern in 'exclude' matches it.
  lint INPUT_PATH=bin/console INPUT_EXCLUDE=bin
  assert_status 1
  assert_output files-checked 1
}

test_path_can_be_a_symbolic_link_to_a_directory() {
  put releases/42/src/broken.php "$PARSE_ERROR"
  if ! ln -s releases/42 "$SANDBOX/current" 2> /dev/null; then
    skip "cannot create symbolic links here"
    return
  fi
  lint INPUT_PATH=current
  assert_status 1
  assert_contains "$OUTPUT" "✖ current/src/broken.php:2 - Parse error"
  assert_output files-checked 1
}

test_exclude_accepts_absolute_paths() {
  put src/ok.php "$VALID"
  put src/generated/broken.php "$PARSE_ERROR"
  lint "INPUT_PATH=$SANDBOX/src" "INPUT_EXCLUDE=$SANDBOX/src/generated"
  assert_status 0
  assert_output files-checked 1
}

test_overlapping_paths_are_linted_once() {
  put src/broken.php "$PARSE_ERROR"
  lint "INPUT_PATH=src, src/broken.php, ."
  assert_status 1
  assert_output files-checked 1
  assert_output errors 1
}

test_missing_path_is_an_error() {
  put src/ok.php "$VALID"
  lint INPUT_PATH=nope
  assert_status 2
  assert_contains "$OUTPUT" "Path 'nope' does not exist"
}

test_no_files_is_an_error() {
  put README.md "# nothing to lint"
  lint
  assert_status 2
  assert_contains "$OUTPUT" "No PHP files found to lint"
}

test_symlinks_are_not_followed() {
  put src/ok.php "$VALID"
  put outside/broken.php "$PARSE_ERROR"
  if ! ln -s "$SANDBOX/outside" "$SANDBOX/src/linked-dir" 2> /dev/null ||
    ! ln -s "$SANDBOX/outside/broken.php" "$SANDBOX/src/linked.php" 2> /dev/null ||
    ! ln -s .. "$SANDBOX/src/loop" 2> /dev/null; then
    skip "cannot create symbolic links here"
    return
  fi
  lint INPUT_PATH=src
  assert_status 0
  assert_output files-checked 1
}

test_unreadable_file_is_an_error() {
  if [[ $(id -u) -eq 0 ]]; then
    skip "root can read every file"
    return
  fi
  put src/secret.php "$VALID"
  chmod 000 "$SANDBOX/src/secret.php"
  lint
  chmod 644 "$SANDBOX/src/secret.php"
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/secret.php - Error: Could not open input file"
  assert_output errors 1
}

test_unreadable_directory_is_an_error() {
  if [[ $(id -u) -eq 0 ]]; then
    skip "root can read every directory"
    return
  fi
  put src/ok.php "$VALID"
  put data/private/file.php "$VALID"
  chmod 000 "$SANDBOX/data/private"
  lint
  local status=$STATUS output=$OUTPUT
  lint INPUT_EXCLUDE=data/private
  chmod 755 "$SANDBOX/data/private"
  assert_equals "$status" 2 "exit status when a directory cannot be read"
  assert_contains "$output" "Could not read everything under the given paths"
  assert_status 0
  assert_output files-checked 1
}

test_awkward_file_names() {
  local name count=0
  local -a names=(
    'with space.php'
    'two  spaces  .php'
    "single'quote.php"
    'double"quote.php'
    '$(touch injected).php'
    '`touch injected`.php'
    'semi;colon & amp | pipe.php'
    'glob*star?mark[abc].php'
    '-leading-dash.php'
    '--worker.php'
    'ünï¢ødé-日本語.php'
    'percent%41,comma:colon.php'
    'back\slash.php'
    'tab	here.php'
    'new
line.php'
  )
  for name in "${names[@]}"; do
    put "ok/$name" "$VALID"
    put "broken/$name" "$PARSE_ERROR"
    count=$((count + 1))
  done

  lint
  assert_status 1
  assert_output files-checked $((count * 2))
  assert_output errors "$count"
  assert_contains "$OUTPUT" "✖ broken/with space.php:2 - Parse error"
  assert_contains "$OUTPUT" "✖ broken/\$(touch injected).php:2 - Parse error"
  assert_contains "$OUTPUT" "✖ broken/-leading-dash.php:2 - Parse error"
  assert_contains "$OUTPUT" "✖ broken/ünï¢ødé-日本語.php:2 - Parse error"
  # Control characters are shown as spaces, so that every problem stays on one line.
  assert_contains "$OUTPUT" "✖ broken/tab here.php:2 - Parse error"
  assert_contains "$OUTPUT" "✖ broken/new line.php:2 - Parse error"
  # File names are data, never code.
  if [[ -e "$SANDBOX/injected" || -e "$SANDBOX/ok/injected" || -e "$SANDBOX/broken/injected" ]]; then
    fail "a file name was executed as a command"
  fi
}

# ---------------------------------------------------------------------------
# GitHub Actions integration
# ---------------------------------------------------------------------------

test_annotations() {
  put src/broken.php "$PARSE_ERROR"
  put src/odd.php "$WARNING"
  lint GITHUB_ACTIONS=true
  assert_status 1
  assert_contains "$OUTPUT" "::group::Annotations"
  assert_contains "$OUTPUT" "::error file=src/broken.php,line=2,title=PHP Parse error::syntax error"
  assert_contains "$OUTPUT" "::warning file=src/odd.php,line=2,title=PHP Warning::Unsupported declare 'foo'"
  assert_contains "$OUTPUT" "::endgroup::"
}

test_annotations_escape_special_characters() {
  put 'src/100%,a:b.php' "$PARSE_ERROR"
  lint GITHUB_ACTIONS=true
  assert_status 1
  assert_contains "$OUTPUT" "::error file=src/100%25%2Ca%3Ab.php,line=2,title=PHP Parse error::"
}

test_annotations_can_be_disabled() {
  put src/broken.php "$PARSE_ERROR"
  lint GITHUB_ACTIONS=true INPUT_ANNOTATIONS=false
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/broken.php:2"
  assert_not_contains "$OUTPUT" "::error"
  assert_not_contains "$OUTPUT" "::group::"
}

test_no_annotations_outside_github_actions() {
  put src/broken.php "$PARSE_ERROR"
  lint
  assert_status 1
  assert_not_contains "$OUTPUT" "::error"

  lint INPUT_ANNOTATIONS=true
  assert_contains "$OUTPUT" "::error file=src/broken.php,line=2"
}

test_no_annotations_without_problems() {
  put src/ok.php "$VALID"
  lint GITHUB_ACTIONS=true
  assert_status 0
  assert_not_contains "$OUTPUT" "::"
}

test_annotations_are_capped() {
  local i
  for i in $(seq 1 60); do
    put "src/broken$i.php" "$PARSE_ERROR"
  done
  lint GITHUB_ACTIONS=true
  assert_status 1
  assert_output errors 60
  assert_equals "$(printf '%s\n' "$OUTPUT" | grep -c '^::error ')" 50 "number of error annotations"
  # The log still lists every problem.
  assert_equals "$(printf '%s\n' "$OUTPUT" | grep -c '^  ✖ ')" 60 "number of problems in the log"
}

test_usage_errors_are_annotated() {
  put src/ok.php "$VALID"
  lint GITHUB_ACTIONS=true INPUT_PATH=nope
  assert_status 2
  assert_contains "$OUTPUT" "::error title=PHP Lint::Path 'nope' does not exist"
}

test_job_summary_on_success() {
  put src/ok.php "$VALID"
  lint
  assert_contains "$(summary)" "### PHP Lint" "job summary"
  assert_contains "$(summary)" "✅ **No syntax errors** in 1 file checked with PHP $PHP_VERSION." "job summary"
  assert_not_contains "$(summary)" "| File |" "job summary"
}

test_job_summary_lists_problems() {
  put src/ok.php "$VALID"
  put src/broken.php "$PARSE_ERROR"
  put src/odd.php "$WARNING"
  lint
  assert_contains "$(summary)" "❌ **1 syntax error** and 1 warning in 3 files checked with PHP $PHP_VERSION." "job summary"
  assert_contains "$(summary)" "| ❌ | <code>src/broken.php</code> | 2 | <strong>Parse error:</strong> syntax error" "job summary"
  assert_contains "$(summary)" "| ⚠️ | <code>src/odd.php</code> | 2 | <strong>Warning:</strong> Unsupported declare 'foo' |" "job summary"
}

test_job_summary_for_errors_only() {
  put src/a.php "$PARSE_ERROR"
  put src/b.php "$FATAL_ERROR"
  put src/ok.php "$VALID"
  lint
  assert_contains "$(summary)" "❌ **2 syntax errors** in 3 files checked with PHP $PHP_VERSION." "job summary"
}

test_job_summary_for_warnings_only() {
  put src/odd.php "$WARNING"
  lint
  assert_contains "$(summary)" "⚠️ **No syntax errors**, but 1 warning in 1 file checked with PHP $PHP_VERSION." "job summary"
}

test_job_summary_escapes_markdown() {
  put 'src/a|b<i>*c*_d_`e`[f]#1@g$h~.php' "$PARSE_ERROR"
  lint
  assert_status 1
  assert_contains "$(summary)" "<code>src/a&#124;b&lt;i&gt;&#42;c&#42;&#95;d&#95;&#96;e&#96;&#91;f&#93;&#35;1&#64;g&#36;h&#126;.php</code>" "job summary"
}

test_job_summary_is_capped() {
  local i
  for i in $(seq 1 105); do
    put "src/broken$i.php" "$PARSE_ERROR"
  done
  lint
  assert_equals "$(summary | grep -c '^| ❌ ')" 100 "number of rows in the job summary"
  assert_contains "$(summary)" "_Showing the first 100 of 105 problems; the job log lists all of them._" "job summary"
}

test_comment_setting_is_passed_on() {
  put src/ok.php "$VALID"

  lint
  assert_output comment true

  lint INPUT_COMMENT=false
  assert_output comment false

  lint INPUT_COMMENT=no
  assert_output comment false

  # ...also when the lint fails, so that the comment can report the failure.
  put src/broken.php "$PARSE_ERROR"
  lint INPUT_COMMENT=true
  assert_status 1
  assert_output comment true

  lint INPUT_COMMENT=maybe
  assert_status 2
  assert_contains "$OUTPUT" "Invalid value 'maybe' for 'comment': expected true or false."
}

test_report_file() {
  put src/ok.php "$VALID"
  put src/broken.php "$PARSE_ERROR"
  local report

  lint "PHP_LINT_REPORT_FILE=$META/report.md"
  assert_status 1
  assert_output report-file "$META/report.md"
  report="$(cat "$META/report.md")"
  assert_contains "$report" "❌ **1 syntax error** in 2 files checked with PHP $PHP_VERSION." "report"
  assert_contains "$report" "| ❌ | <code>src/broken.php</code> | 2 | <strong>Parse error:</strong> syntax error" "report"
  # The report is the job summary without its heading.
  assert_not_contains "$report" "### PHP Lint" "report"
  assert_equals "$(summary)" "$(printf '### PHP Lint\n\n%s' "$report")" "job summary"

  # The file is written on success too.
  lint INPUT_PATH=src/ok.php "PHP_LINT_REPORT_FILE=$META/report.md"
  assert_status 0
  assert_equals "$(cat "$META/report.md")" "✅ **No syntax errors** in 1 file checked with PHP $PHP_VERSION." "report"

  # Without a file, the output is empty.
  lint
  assert_output report-file ""

  # The report only serves the comment: nothing is written when it is off.
  rm "$META/report.md"
  lint INPUT_PATH=src/ok.php INPUT_COMMENT=false "PHP_LINT_REPORT_FILE=$META/report.md"
  assert_status 0
  assert_output report-file ""
  if [[ -e "$META/report.md" ]]; then
    fail "the report was written although the comment is off"
  fi
}

test_unwritable_report_file_does_not_change_the_result() {
  put src/ok.php "$VALID"
  lint "PHP_LINT_REPORT_FILE=$META/nonexistent/report.md"
  assert_status 0
  assert_contains "$OUTPUT" "php-lint: warning: Could not write the report to '$META/nonexistent/report.md', so the pull request comment is skipped."
  assert_contains "$OUTPUT" "No syntax errors detected in 1 file"
  assert_output files-checked 1
  assert_output report-file ""
  assert_contains "$(summary)" "✅ **No syntax errors**" "job summary"

  lint GITHUB_ACTIONS=true "PHP_LINT_REPORT_FILE=$META/nonexistent/report.md"
  assert_status 0
  assert_contains "$OUTPUT" "::warning title=PHP Lint::Could not write the report to"
}

test_runs_from_the_github_workspace() {
  put repo/src/broken.php "$PARSE_ERROR"
  put elsewhere/ok.php "$VALID"
  lint "GITHUB_WORKSPACE=$SANDBOX/repo" GITHUB_ACTIONS=true
  assert_status 1
  assert_output files-checked 1
  assert_contains "$OUTPUT" "::error file=src/broken.php,line=2"
}

test_uses_runner_temp() {
  put src/ok.php "$VALID"
  mkdir "$META/runner-temp"
  lint "RUNNER_TEMP=$META/runner-temp" TMPDIR=/nonexistent
  assert_status 0
  # ...and cleans up after itself.
  assert_equals "$(find "$META/runner-temp" -mindepth 1 | wc -l | tr -d '[:space:]')" 0 "files left in RUNNER_TEMP"
}

# ---------------------------------------------------------------------------
# Settings and environment
# ---------------------------------------------------------------------------

test_boolean_settings() {
  put src/odd.php "$WARNING"
  local value
  for value in true TRUE yes on 1; do
    lint "INPUT_FAIL_ON_WARNINGS=$value"
    assert_status 1
  done
  for value in false False no off 0 ''; do
    lint "INPUT_FAIL_ON_WARNINGS=$value"
    assert_status 0
  done
}

test_invalid_boolean_is_an_error() {
  put src/ok.php "$VALID"
  lint INPUT_FAIL_ON_WARNINGS=maybe
  assert_status 2
  assert_contains "$OUTPUT" "Invalid value 'maybe' for 'fail-on-warnings': expected true or false."

  lint INPUT_ANNOTATIONS=sometimes
  assert_status 2
  assert_contains "$OUTPUT" "Invalid value 'sometimes' for 'annotations'"
}

test_missing_php_is_an_error() {
  put src/ok.php "$VALID"
  local tool
  mkdir "$META/bin"
  for tool in dirname basename; do
    ln -s "$(command -v "$tool")" "$META/bin/$tool"
  done
  lint "PATH=$META/bin"
  assert_status 2
  assert_contains "$OUTPUT" "PHP was not found on PATH"
}

# fake_tool <name> <script body>: creates a stand-in for a program in $META/fake;
# run the lint with "PATH=$META/fake:$PATH" to use it. The body can call the real
# PHP interpreter as "$REAL_PHP".
fake_tool() {
  mkdir -p "$META/fake"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REAL_PHP=%q\n' "$REAL_PHP"
    printf '%s\n' "$2"
  } > "$META/fake/$1"
  chmod +x "$META/fake/$1"
}

test_startup_messages_of_php_are_ignored() {
  put src/ok.php "$VALID"
  put src/odd.php "$WARNING"
  fake_tool php 'echo "PHP Warning:  Module \"curl\" is already loaded in Unknown on line 0" >&2
echo "Xdebug: [Step Debug] Could not connect to debugging client." >&2
exec "$REAL_PHP" "$@"'
  lint "PATH=$META/fake:$PATH"
  assert_status 0
  assert_output files-checked 2
  assert_output errors 0
  assert_output warnings 1
  assert_not_contains "$OUTPUT" "already loaded"
  assert_not_contains "$OUTPUT" "Xdebug"
}

test_log_format_of_php_is_understood() {
  # What PHP prints when a php.ini sends errors to the log (stderr) as well.
  put src/broken.php "$PARSE_ERROR"
  fake_tool php 'for argument in "$@"; do file=$argument; done
if [[ " $* " == *" -l "* ]]; then
  echo "PHP Parse error:  syntax error, unexpected end of file in $file on line 7" >&2
  printf "\nParse error: syntax error, unexpected end of file in %s on line 7\n" "$file"
  echo "Errors parsing $file"
  exit 255
fi
exec "$REAL_PHP" "$@"'
  lint "PATH=$META/fake:$PATH"
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/broken.php:7 - Parse error: syntax error, unexpected end of file"
  assert_output errors 1
}

test_crashing_php_is_an_error() {
  put src/ok.php "$VALID"
  put src/crash.php "$VALID"
  fake_tool php 'if [[ " $* " == *" -l "* && "$*" == *crash.php ]]; then
  exit 139
fi
exec "$REAL_PHP" "$@"'
  lint "PATH=$META/fake:$PATH"
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/crash.php - Error: php -l exited with status 139"
  assert_output errors 1
}

test_php_that_cannot_start_is_an_error() {
  put src/ok.php "$VALID"
  fake_tool php 'if [[ " $* " == *" -l "* ]]; then
  echo "PHP Fatal error:  Unable to start standard module in Unknown on line 0"
  exit 255
fi
exec "$REAL_PHP" "$@"'
  lint "PATH=$META/fake:$PATH"
  assert_status 1
  assert_contains "$OUTPUT" "✖ src/ok.php - Error: PHP Fatal error:  Unable to start standard module in Unknown on line 0"
}

# Files that were not linted must never be reported as "no syntax errors".
test_failed_worker_is_an_error() {
  put src/a.php "$VALID"
  fake_tool xargs 'cat > /dev/null
exit 125'
  lint "PATH=$META/fake:$PATH"
  assert_status 2
  assert_contains "$OUTPUT" "A lint worker stopped unexpectedly; the results would be incomplete."
  assert_not_contains "$OUTPUT" "No syntax errors detected"
}

test_skipped_files_are_an_error() {
  put src/a.php "$VALID"
  put src/b.php "$VALID"
  fake_tool xargs 'cat > /dev/null'
  lint "PATH=$META/fake:$PATH"
  assert_status 2
  assert_contains "$OUTPUT" "Only 0 of 2 files were linted; the results would be incomplete."
  assert_not_contains "$OUTPUT" "No syntax errors detected"
}

# ---------------------------------------------------------------------------

passed_count=0
failed_count=0
skipped_count=0
filter=${1:-}

printf 'PHP %s, bash %s\n\n' "$PHP_VERSION" "$BASH_VERSION"
while read -r _ _ name; do
  if [[ $name == test_* && $name == *"$filter"* ]]; then
    run_test "$name"
  fi
done < <(declare -F)

printf '\n%s passed, %s failed, %s skipped\n' "$passed_count" "$failed_count" "$skipped_count"
if [[ $failed_count -gt 0 || $passed_count -eq 0 ]]; then
  exit 1
fi
