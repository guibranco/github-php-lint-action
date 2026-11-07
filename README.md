# GitHub PHP Lint Action

[![GitHub repo](https://img.shields.io/badge/GitHub-guibranco%2Fgithub--php--lint--action-green.svg?style=plastic&logo=github)](https://github.com/guibranco/github-php-lint-action "shields.io")
[![GitHub last commit](https://img.shields.io/github/last-commit/guibranco/github-php-lint-action?color=green&logo=github&style=plastic&label=Last%20commit)](https://github.com/guibranco/github-php-lint-action "shields.io")
[![GitHub license](https://img.shields.io/github/license/guibranco/github-php-lint-action?color=green&logo=github&style=plastic&label=License)](https://github.com/guibranco/github-php-lint-action "shields.io")

![CI](https://github.com/guibranco/github-php-lint-action/actions/workflows/ci.yml/badge.svg)

🐘 :octocat: A GitHub action to check PHP files for syntax errors with `php -l`, on the PHP version you choose.

---

## Usage

The following workflow steps check every `.php` file of the repository. Unless the repository pins a PHP version (see [PHP version](#php-version)), the latest stable PHP release is used.

```yml
- name: Checkout
  uses: actions/checkout@v7

- name: PHP Lint
  uses: guibranco/github-php-lint-action@v1.1.0
```

The step fails when a file has a syntax error. Every problem is listed in the job log and in the job summary, shown as an annotation on the line it was found, and posted as a comment on the pull request (see [Pull request comment](#pull-request-comment)).

---

## Inputs

| Input              | Description                                                                                                         | Required | Default                 |
| ------------------ | ------------------------------------------------------------------------------------------------------------------- | -------- | ----------------------- |
| `php-version`      | PHP version to lint with: `8.5`, `8.6`, `latest`, `nightly`… See [PHP version](#php-version)                        | No       | Detected, else `latest` |
| `setup-php`        | Install the PHP version above before linting. Set to `false` to lint with the `php` that is already on `PATH`       | No       | `true`                  |
| `path`             | Files or directories to lint, relative to the repository root. Newline or comma separated                           | No       | `.`                     |
| `exclude`          | Files, directories or patterns to skip. Newline or comma separated. See [Excluding files](#excluding-files)         | No       | `vendor,node_modules`   |
| `extensions`       | File extensions to lint. Newline or comma separated                                                                 | No       | `php`                   |
| `fail-on-warnings` | Fail when PHP reports warnings or deprecations while compiling a file                                               | No       | `false`                 |
| `annotations`      | Add an inline annotation for every problem found                                                                    | No       | `true`                  |
| `comment`          | Post the result as a comment on the pull request. See [Pull request comment](#pull-request-comment)                | No       | `true`                  |
| `github-token`     | Token used to comment on the pull request                                                                           | No       | `${{ github.token }}`   |

---

## Outputs

| Output          | Description                                          |
| --------------- | ---------------------------------------------------- |
| `php-version`   | The full PHP version the files were linted with      |
| `files-checked` | The number of files that were linted                 |
| `errors`        | The number of syntax errors found                    |
| `warnings`      | The number of warnings and deprecations PHP reported |
| `comment-url`   | The URL of the comment posted on the pull request, when one was |

---

## Examples

### Basic usage with default settings

```yml
name: PHP Linting

on:
  push:
    branches:
      - main
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write # to comment on the pull request

jobs:
  php-lint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: PHP Lint
        uses: guibranco/github-php-lint-action@v1.1.0
```

---

### With a specific PHP version

```yml
- name: PHP Lint
  uses: guibranco/github-php-lint-action@v1.1.0
  with:
    php-version: "8.4"
```

---

### With several PHP versions

Lint with every PHP version the project supports, plus the next one to see what is coming:

```yml
jobs:
  php-lint:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        php-version: ["8.3", "8.4", "8.5", "nightly"]
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: PHP Lint
        uses: guibranco/github-php-lint-action@v1.1.0
        with:
          php-version: ${{ matrix.php-version }}
```

---

### Choosing what is linted

```yml
- name: PHP Lint
  uses: guibranco/github-php-lint-action@v1.1.0
  with:
    path: |
      src
      tests
      bin/console
    exclude: |
      vendor
      tests/fixtures
      *.generated.php
    extensions: php, phtml, inc
```

Directories are searched for files with the given extensions. A file listed in `path`, like `bin/console` here, is linted whatever its extension.

---

### Treating warnings and deprecations as errors

```yml
- name: PHP Lint
  uses: guibranco/github-php-lint-action@v1.1.0
  with:
    fail-on-warnings: true
```

---

### Without the pull request comment

```yml
- name: PHP Lint
  uses: guibranco/github-php-lint-action@v1.1.0
  with:
    comment: false
```

---

### Using the PHP that is already installed

When the job already sets PHP up (with its own extensions and `php.ini` values), or runs in a container that ships PHP, skip the installation so the action leaves that setup untouched:

```yml
jobs:
  php-lint:
    runs-on: ubuntu-latest
    container: php:8.5-cli
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: PHP Lint
        uses: guibranco/github-php-lint-action@v1.1.0
        with:
          setup-php: false
```

The container needs `bash`; the Alpine variants of the PHP images do not include it.

---

### Using outputs in subsequent steps

```yml
- name: PHP Lint
  id: php-lint
  uses: guibranco/github-php-lint-action@v1.1.0

- name: Show the result
  if: always()
  run: |
    echo "PHP ${{ steps.php-lint.outputs.php-version }}"
    echo "${{ steps.php-lint.outputs.files-checked }} files checked"
    echo "${{ steps.php-lint.outputs.errors }} errors, ${{ steps.php-lint.outputs.warnings }} warnings"
    echo "Comment: ${{ steps.php-lint.outputs.comment-url }}"
```

---

## Sample outputs

### Job log

```
PHP 8.5.12 - linting 25 files with 4 parallel jobs

  ✖ src/Api/Jobs.php:42 - Parse error: syntax error, unexpected token "}"
  ⚠ src/Service/Github.php:17 - Deprecated: fetch(): Implicitly marking parameter $token as nullable is deprecated, the explicit nullable type must be used instead

❌ 25 files checked: 1 error, 1 warning
```

### Job summary

> ### PHP Lint
>
> ❌ **1 syntax error** and 1 warning in 25 files checked with PHP 8.5.12.
>
> |     | File                     | Line | Message                                                                                                                                         |
> | :-: | :----------------------- | ---: | :---------------------------------------------------------------------------------------------------------------------------------------------- |
> | ❌  | `src/Api/Jobs.php`       |   42 | **Parse error:** syntax error, unexpected token "}"                                                                                             |
> | ⚠️  | `src/Service/Github.php` |   17 | **Deprecated:** fetch(): Implicitly marking parameter $token as nullable is deprecated, the explicit nullable type must be used instead |

### Comment on the pull request

> ### 🐘 PHP Lint
>
> ❌ **1 syntax error** and 1 warning in 25 files checked with PHP 8.5.12.
>
> |     | File                     | Line | Message                                                                                                                                         |
> | :-: | :----------------------- | ---: | :---------------------------------------------------------------------------------------------------------------------------------------------- |
> | ❌  | `src/Api/Jobs.php`       |   42 | **Parse error:** syntax error, unexpected token "}"                                                                                             |
> | ⚠️  | `src/Service/Github.php` |   17 | **Deprecated:** fetch(): Implicitly marking parameter $token as nullable is deprecated, the explicit nullable type must be used instead |
>
> <sub>Posted by [github-php-lint-action](https://github.com/guibranco/github-php-lint-action) · [Workflow run](#)</sub>

### Annotations

Each problem is also attached to its file and line, so it shows up in the **Files changed** tab of the pull request and in the run summary. GitHub only displays a limited number of annotations per step; the job log always lists every problem, and the job summary the first 100.

---

## Features

- 🐘 **Any PHP version**, from 5.6 to the nightly build of the next release, installed with [shivammathur/setup-php](https://github.com/shivammathur/setup-php)
- ⚡ **Parallel linting**, one `php -l` process per CPU core
- 🎯 **Inline annotations** on the offending file and line
- 📊 **Job summary** with every error and warning
- 💬 **Pull request comment** with the result, updated in place on every run
- ⚠️ **Warnings and deprecations** PHP reports while compiling are surfaced, and can fail the build
- 🧹 **Sensible defaults**: `vendor` and `node_modules` are skipped
- 📎 **Workflow-friendly outputs**
- 🪶 **No dependencies to install** in your project: no Composer packages, no Docker image to build

---

## PHP version

`php-version` accepts what [shivammathur/setup-php](https://github.com/shivammathur/setup-php#php-version-optional) accepts: a version such as `8.5` or `8.4`, or `latest`, `nightly`, `8.x`…

When the input is not set, the version is taken from, in this order:

1. A `.php-version` file at the repository root
2. `platform-overrides.php` in `composer.lock`
3. `config.platform.php` in `composer.json`
4. The latest stable PHP release

Lint with the PHP version the code runs on: a newer version reports deprecations the production version does not have, and an older one rejects syntax it does not know yet.

Versions that are still in development (`nightly`, or the number of the next release) are nightly builds, so a failure there can come from PHP itself.

The action switches the job to the PHP version it installs. Use `setup-php: false` if later steps of the same job depend on a PHP setup made earlier.

---

## Pull request comment

On `pull_request` and `pull_request_target` events, the result is posted as a comment on the pull request: the status line and, when there are problems, the same table as the job summary. The next run of the action updates that comment instead of adding another one, so a pull request keeps a single, current comment per PHP version: a workflow that lints with several `php-version` values gets one comment for each. When `php-version` is not set and the job brings its own PHP (`setup-php: false`), the PHP version found on `PATH` tells the comments apart.

The comment needs the `pull-requests: write` permission:

```yml
permissions:
  contents: read
  pull-requests: write
```

When the comment cannot be posted, the lint result is not affected: the step logs why and goes on. That is the case on pull requests from forks and from Dependabot, where the `GITHUB_TOKEN` is read-only, and when the permission above is missing, which is reported as a warning.

Set `comment: false` to turn the comment off, or give `github-token` a token of your own (a GitHub App token, for example) to post it as another identity. The job summary and the annotations do not depend on the comment.

---

## Excluding files

Each entry of `exclude` is a file, a directory or a wildcard pattern, relative to the repository root. It is matched at the root and at any depth below it:

| Entry                | Skips                                                      |
| -------------------- | ---------------------------------------------------------- |
| `vendor`             | `vendor/`, `src/vendor/`, `packages/api/vendor/`…          |
| `tests/fixtures`     | `tests/fixtures/`, `packages/api/tests/fixtures/`…         |
| `src/legacy/old.php` | That file                                                  |
| `*.generated.php`    | Every file whose name ends in `.generated.php`, anywhere   |
| `cache*`             | Every file or directory whose name starts with `cache`     |

Setting `exclude` replaces the default list, so keep `vendor` in it if the job installs Composer packages; `exclude: ""` skips nothing. The `.git` directory is never linted, and symbolic links are not followed.

---

## What is checked

Every file is compiled with `php -l`, which finds:

- **Syntax errors**, such as a missing brace or syntax that the chosen PHP version does not support
- **Compile-time fatal errors**, such as a function declared twice in one file, or a method that is incompatible with the built-in class it extends
- **Warnings and deprecations** raised while compiling, reported as warnings

Nothing is executed and other files are not loaded, so problems that only show at runtime (an undefined function, a missing class) are out of scope: that is the job of a static analyser such as PHPStan or Psalm.

PHP runs with the `php.ini` of the installation. With the default setup that is the production configuration, where `short_open_tag` is off: code between `<?` and `?>` is treated as text, like on most servers.

If no file matches, the step fails instead of reporting success: a lint that checked nothing usually means a missing checkout or a wrong `path`.

---

## Migrating from michaelw90/PHP-Lint

[michaelw90/PHP-Lint](https://github.com/michaelw90/PHP-Lint) has not been updated since 2020 and lints with PHP 7.3. This action is a new implementation that can replace it by changing one line:

```diff
       - name: Check PHP Lint
-        uses: michaelw90/PHP-Lint@master
+        uses: guibranco/github-php-lint-action@v1.1.0
```

What changes:

- The PHP version is yours to choose, and defaults to the latest stable release instead of PHP 7.3
- A `.phplint.yml` file is not read: use the `path`, `exclude` and `extensions` inputs
- `vendor` and `node_modules` are skipped by default
- Errors are annotated on the pull request, listed in the job summary and posted as a comment

---

## Permissions

The action reads the files of the workspace and comments on the pull request:

```yml
permissions:
  contents: read
  pull-requests: write # not needed with 'comment: false'
```

---

## Runners

The action is tested on GitHub-hosted Ubuntu runners. The lint script only needs `bash` 3.2 or newer, `find`, `sort` and `xargs`, so it also runs with the PHP of a container or of a self-hosted runner when `setup-php` is `false`. The pull request comment is posted with [actions/github-script](https://github.com/actions/github-script), which runs wherever JavaScript actions do.

---

## Development

The action is a composite action: [action.yml](action.yml) installs PHP, runs [scripts/php-lint.sh](scripts/php-lint.sh) and posts the comment with [scripts/pr-comment.js](scripts/pr-comment.js).

```bash
# Run the test suite of the lint script with the php executable on PATH
tests/run-tests.sh

# Run only the tests whose name contains "exclude"
tests/run-tests.sh exclude

# Run the tests of the comment script
node --test tests/*.test.js

# Lint a directory with the script, without GitHub Actions
INPUT_PATH=src scripts/php-lint.sh
```

The [CI workflow](.github/workflows/ci.yml) runs ShellCheck, both test suites (the lint script on every supported PHP version) and the action itself, which comments on the repository's own pull requests. Every push to `main` that passes is released automatically, with the version computed by GitVersion: the patch number by default, or more when the commit message contains `+semver: minor` or `+semver: major`.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
