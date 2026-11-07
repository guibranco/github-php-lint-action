#!/usr/bin/env bash
#
# Checks the PHP Lint comments on a pull request. The CI workflow of this
# repository runs it after using the action on its own pull requests.
#
#   tests/check-pr-comments.sh <pull request number> <expectation>...
#
# Each expectation is one of:
#   KEY=TEXT    the comment for the PHP version KEY exists once and contains TEXT
#   KEY!=TEXT   the comment for the PHP version KEY exists once and does not contain TEXT
#   !KEY        there is no comment for the PHP version KEY
# where KEY is the php-version input the action was run with ("" when it was not set).
#
# Needs the gh CLI with a token that can read the pull request (GH_TOKEN), and
# GITHUB_REPOSITORY.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <pull request number> <expectation>..." >&2
  exit 2
fi

pull_request=$1
shift

comments="$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$pull_request/comments?per_page=100")"
failures=0

marker() {
  printf '<!-- github-php-lint-action php-version="%s" -->' "$1"
}

# Prints the bodies of the comments carrying the marker of a PHP version key.
bodies_of() {
  jq -r -s --arg marker "$(marker "$1")" '[.[][] | select((.body // "") | contains($marker)) | .body] | join("\n----\n")' <<< "$comments"
}

count_of() {
  jq -r -s --arg marker "$(marker "$1")" '[.[][] | select((.body // "") | contains($marker))] | length' <<< "$comments"
}

for expectation in "$@"; do
  if [[ $expectation == !* && $expectation != *"!="* ]]; then
    key=${expectation#!}
    count="$(count_of "$key")"
    if [[ $count -eq 0 ]]; then
      printf 'ok      no comment for php-version "%s"\n' "$key"
    else
      printf '::error::expected no comment for php-version "%s", found %s\n' "$key" "$count"
      failures=$((failures + 1))
    fi
    continue
  fi

  negated=false
  if [[ $expectation == *"!="* ]]; then
    key=${expectation%%!=*}
    text=${expectation#*!=}
    negated=true
  else
    key=${expectation%%=*}
    text=${expectation#*=}
  fi

  count="$(count_of "$key")"
  if [[ $count -ne 1 ]]; then
    printf '::error::expected exactly one comment for php-version "%s", found %s\n' "$key" "$count"
    failures=$((failures + 1))
    continue
  fi
  body="$(bodies_of "$key")"
  if [[ $negated == false && $body == *"$text"* ]]; then
    printf 'ok      comment for php-version "%s" contains: %s\n' "$key" "$text"
  elif [[ $negated == true && $body != *"$text"* ]]; then
    printf 'ok      comment for php-version "%s" does not contain: %s\n' "$key" "$text"
  else
    printf '::error::the comment for php-version "%s" %s: %s\n' "$key" \
      "$([[ $negated == true ]] && echo 'should not contain' || echo 'does not contain')" "$text"
    printf '%s\n' "$body" | sed 's/^/        | /'
    failures=$((failures + 1))
  fi
done

if [[ $failures -gt 0 ]]; then
  exit 1
fi
