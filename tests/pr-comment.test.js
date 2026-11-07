// Tests for scripts/pr-comment.js. Run them with `node --test tests/`.

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { afterEach, beforeEach, describe, it } = require('node:test');

const postComment = require('../scripts/pr-comment.js');
const { buildBody, marker, MAX_BODY_LENGTH } = postComment;

const SUCCESS_REPORT = '✅ **No syntax errors** in 3 files checked with PHP 8.5.12.\n';
const FAILURE_REPORT = [
  '❌ **1 syntax error** and 1 warning in 3 files checked with PHP 8.5.12.',
  '',
  '| | File | Line | Message |',
  '|:-:|:--|--:|:--|',
  '| ❌ | <code>src/broken.php</code> | 2 | <strong>Parse error:</strong> syntax error, unexpected token "{" |',
  '| ⚠️ | <code>src/odd.php</code> | 2 | <strong>Warning:</strong> Unsupported declare &#39;foo&#39; |',
  '',
].join('\n');

// A fake of the parts of actions/github-script that the script uses.
function fakeGitHub({ comments = [], failWith } = {}) {
  const calls = [];
  const github = {
    rest: {
      issues: {
        listComments: 'listComments',
        updateComment: async (params) => {
          calls.push(['updateComment', params]);
          if (failWith) {
            throw failWith;
          }
          return { data: { id: params.comment_id, html_url: `https://github.com/o/r/pull/7#issuecomment-${params.comment_id}` } };
        },
        createComment: async (params) => {
          calls.push(['createComment', params]);
          if (failWith) {
            throw failWith;
          }
          return { data: { id: 900, html_url: 'https://github.com/o/r/pull/7#issuecomment-900' } };
        },
      },
    },
    paginate: async (method, params) => {
      calls.push(['listComments', params]);
      assert.equal(method, 'listComments');
      if (failWith) {
        throw failWith;
      }
      return comments;
    },
  };
  return { github, calls };
}

function fakeCore() {
  const logs = { info: [], warning: [], error: [] };
  return {
    logs,
    info: (message) => logs.info.push(message),
    warning: (message) => logs.warning.push(message),
    error: (message) => logs.error.push(message),
  };
}

function fakeContext({ pullRequest = { number: 7 }, actor = 'octocat' } = {}) {
  return {
    payload: pullRequest ? { pull_request: pullRequest } : {},
    repo: { owner: 'o', repo: 'r' },
    serverUrl: 'https://github.com',
    runId: 123,
    actor,
  };
}

function apiError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

describe('marker', () => {
  it('identifies the comment of a PHP version', () => {
    assert.equal(marker('8.4'), '<!-- github-php-lint-action php-version="8.4" -->');
    assert.equal(marker(''), '<!-- github-php-lint-action php-version="" -->');
    assert.equal(marker(undefined), '<!-- github-php-lint-action php-version="" -->');
  });

  it('cannot be broken out of', () => {
    assert.equal(marker('8.4 --> <script>'), '<!-- github-php-lint-action php-version="8.4  <script>" -->');
  });
});

describe('buildBody', () => {
  it('wraps the report with the marker, a heading and a footer', () => {
    const body = buildBody({ marker: marker('8.5'), report: SUCCESS_REPORT, runUrl: 'https://github.com/o/r/actions/runs/123' });
    assert.equal(
      body,
      [
        '<!-- github-php-lint-action php-version="8.5" -->',
        '### 🐘 PHP Lint',
        '',
        '✅ **No syntax errors** in 3 files checked with PHP 8.5.12.',
        '',
        '<sub>Posted by [github-php-lint-action](https://github.com/guibranco/github-php-lint-action) · [Workflow run](https://github.com/o/r/actions/runs/123)</sub>',
      ].join('\n')
    );
  });

  it('keeps the table of problems', () => {
    const body = buildBody({ marker: marker(''), report: FAILURE_REPORT, runUrl: '' });
    assert.match(body, /\| ❌ \| <code>src\/broken\.php<\/code> \| 2 \|/);
    assert.match(body, /\| ⚠️ \| <code>src\/odd\.php<\/code> \| 2 \|/);
    assert.doesNotMatch(body, /Workflow run/);
    assert.doesNotMatch(body, /Only the first/);
  });

  it('drops rows from the end when the comment would be too long', () => {
    const rows = [];
    for (let i = 1; i <= 500; i += 1) {
      rows.push(`| ❌ | <code>src/file${i}.php</code> | ${i} | <strong>Parse error:</strong> ${'x'.repeat(200)} |`);
    }
    const report = [
      '❌ **500 syntax errors** in 500 files checked with PHP 8.5.12.',
      '',
      '| | File | Line | Message |',
      '|:-:|:--|--:|:--|',
      ...rows,
      '',
      '_Showing the first 500 of 505 problems; the job log lists all of them._',
    ].join('\n');

    const body = buildBody({ marker: marker(''), report, runUrl: 'https://github.com/o/r/actions/runs/123' });
    assert.ok(body.length <= MAX_BODY_LENGTH, `body has ${body.length} characters`);
    const shown = body.split('\n').filter((line) => line.startsWith('| ❌ |')).length;
    assert.ok(shown > 0 && shown < 500, `${shown} rows are shown`);
    assert.match(body, /\| <code>src\/file1\.php<\/code> \| 1 \|/);
    assert.doesNotMatch(body, /src\/file500\.php/);
    assert.match(body, new RegExp(`_Only the first ${shown} problems are shown in this comment; the job summary and the job log list all of them._`));
    assert.doesNotMatch(body, /Showing the first 500 of 505/);
    assert.match(body, /<sub>Posted by .*<\/sub>$/);
  });
});

describe('postComment', () => {
  let reportFile;
  let env;

  beforeEach(() => {
    reportFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'php-lint-comment-')), 'report.md');
    fs.writeFileSync(reportFile, FAILURE_REPORT);
    env = { PHP_LINT_REPORT_FILE: reportFile, PHP_LINT_COMMENT_KEY: '8.4' };
  });

  afterEach(() => {
    fs.rmSync(path.dirname(reportFile), { recursive: true, force: true });
  });

  it('creates the comment when there is none', async () => {
    const { github, calls } = fakeGitHub();
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext(), core }, env);

    assert.equal(url, 'https://github.com/o/r/pull/7#issuecomment-900');
    assert.deepEqual(
      calls.map(([name]) => name),
      ['listComments', 'createComment']
    );
    const [, params] = calls[1];
    assert.equal(params.owner, 'o');
    assert.equal(params.repo, 'r');
    assert.equal(params.issue_number, 7);
    assert.ok(params.body.startsWith('<!-- github-php-lint-action php-version="8.4" -->\n### 🐘 PHP Lint\n'));
    assert.match(params.body, /src\/broken\.php/);
    assert.match(params.body, /\[Workflow run\]\(https:\/\/github\.com\/o\/r\/actions\/runs\/123\)/);
    assert.deepEqual(core.logs.warning, []);
    assert.match(core.logs.info[0], /Posted a comment on pull request #7/);
  });

  it('updates the comment of the same PHP version and leaves the others alone', async () => {
    const { github, calls } = fakeGitHub({
      comments: [
        { id: 1, body: 'Looks good to me!' },
        { id: 2, body: `${marker('8.3')}\n### 🐘 PHP Lint\n\nold` },
        { id: 3, body: `${marker('8.4')}\n### 🐘 PHP Lint\n\nold` },
        { id: 4, body: null },
      ],
    });
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext(), core }, env);

    assert.equal(url, 'https://github.com/o/r/pull/7#issuecomment-3');
    assert.deepEqual(
      calls.map(([name]) => name),
      ['listComments', 'updateComment']
    );
    assert.equal(calls[1][1].comment_id, 3);
    assert.match(calls[1][1].body, /src\/broken\.php/);
    assert.match(core.logs.info[0], /Updated the comment on pull request #7/);
  });

  it('does nothing outside a pull request', async () => {
    const { github, calls } = fakeGitHub();
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext({ pullRequest: null }), core }, env);

    assert.equal(url, undefined);
    assert.deepEqual(calls, []);
    assert.deepEqual(core.logs.info, ['Not a pull request: no comment to post.']);
  });

  it('warns instead of failing when the report is missing', async () => {
    const { github, calls } = fakeGitHub();
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext(), core }, { PHP_LINT_REPORT_FILE: '/nonexistent/report.md' });

    assert.equal(url, undefined);
    assert.deepEqual(calls, []);
    assert.equal(core.logs.warning.length, 1);
    assert.match(core.logs.warning[0], /Could not read the PHP Lint report '\/nonexistent\/report\.md'/);
  });

  it('warns about the permission when the token cannot comment', async () => {
    const { github } = fakeGitHub({ failWith: apiError(403, 'Resource not accessible by integration') });
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext(), core }, env);

    assert.equal(url, undefined);
    assert.equal(core.logs.warning.length, 1);
    assert.match(core.logs.warning[0], /Could not post the PHP Lint comment on pull request #7 \(HTTP 403\): Resource not accessible by integration\./);
    assert.match(core.logs.warning[0], /needs the 'pull-requests: write' permission/);
  });

  it('only logs when the pull request comes from a fork', async () => {
    const { github } = fakeGitHub({ failWith: apiError(403, 'Resource not accessible by integration') });
    const core = fakeCore();
    const pullRequest = {
      number: 7,
      head: { repo: { fork: true, full_name: 'someone/r' } },
      base: { repo: { full_name: 'o/r' } },
    };

    const url = await postComment({ github, context: fakeContext({ pullRequest }), core }, env);

    assert.equal(url, undefined);
    assert.deepEqual(core.logs.warning, []);
    assert.equal(core.logs.info.length, 1);
    assert.match(core.logs.info[0], /read-only on pull requests from forks/);
  });

  it('only logs when the pull request comes from Dependabot', async () => {
    const { github } = fakeGitHub({ failWith: apiError(403, 'Resource not accessible by integration') });
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext({ actor: 'dependabot[bot]' }), core }, env);

    assert.equal(url, undefined);
    assert.deepEqual(core.logs.warning, []);
    assert.match(core.logs.info[0], /read-only on Dependabot's pull requests/);
  });

  it('never throws on an unexpected API error', async () => {
    const { github } = fakeGitHub({ failWith: new Error('socket hang up') });
    const core = fakeCore();

    const url = await postComment({ github, context: fakeContext(), core }, env);

    assert.equal(url, undefined);
    assert.equal(core.logs.warning.length, 1);
    assert.match(core.logs.warning[0], /Could not post the PHP Lint comment on pull request #7: socket hang up\./);
  });
});
