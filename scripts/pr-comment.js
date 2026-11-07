// Creates or updates the PHP Lint comment on the pull request of the current event.
//
// action.yml runs it through actions/github-script after the lint step, with:
//   PHP_LINT_REPORT_FILE  the Markdown report written by scripts/php-lint.sh
//   PHP_LINT_COMMENT_KEY  the requested PHP version, so that a workflow linting
//                         with several versions keeps one comment per version
//
// It never fails the step: when the comment cannot be posted (the token is
// read-only on pull requests from forks and from Dependabot, or lacks the
// pull-requests: write permission) it says so in the job log and moves on.

'use strict';

const fs = require('fs');

const ACTION_URL = 'https://github.com/guibranco/github-php-lint-action';
const MARKER_PREFIX = '<!-- github-php-lint-action';
const HEADING = '### 🐘 PHP Lint';

// GitHub rejects comment bodies over 65536 characters.
const MAX_BODY_LENGTH = 60000;
const ROW_PATTERN = /^\| (❌|⚠️) \|/;
const REPORT_CAP_NOTE_PATTERN = /^_Showing the first \d+ of \d+ problems;/;

// The hidden marker that identifies the comment to update on the next run.
function marker(key) {
  const safeKey = String(key || '').replace(/-->/g, '').trim();
  return `${MARKER_PREFIX} php-version="${safeKey}" -->`;
}

// Builds the comment body, dropping rows from the end of the table when the
// report is too long for one comment.
function buildBody({ marker: commentMarker, report, runUrl }) {
  let lines = String(report).trimEnd().split('\n');
  let hidden = 0;

  const compose = () => {
    const parts = [commentMarker, HEADING, '', ...lines];
    if (hidden > 0) {
      const shown = lines.filter((line) => ROW_PATTERN.test(line)).length;
      parts.push(
        '',
        `_Only the first ${shown} problems are shown in this comment; the job summary and the job log list all of them._`
      );
    }
    const run = runUrl ? ` · [Workflow run](${runUrl})` : '';
    parts.push('', `<sub>Posted by [github-php-lint-action](${ACTION_URL})${run}</sub>`);
    return parts.join('\n');
  };

  let body = compose();
  while (body.length > MAX_BODY_LENGTH) {
    let last = -1;
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      if (ROW_PATTERN.test(lines[i])) {
        last = i;
        break;
      }
    }
    if (last < 0) {
      break;
    }
    lines.splice(last, 1);
    hidden += 1;
    if (hidden === 1) {
      // This note replaces the one scripts/php-lint.sh may have written.
      lines = lines.filter((line) => !REPORT_CAP_NOTE_PATTERN.test(line));
    }
    body = compose();
  }
  return body;
}

async function findComment(github, { owner, repo, issue_number }, commentMarker) {
  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100,
  });
  return comments.find((comment) => typeof comment.body === 'string' && comment.body.includes(commentMarker));
}

function isFromFork(pullRequest) {
  const head = pullRequest.head && pullRequest.head.repo;
  const base = pullRequest.base && pullRequest.base.repo;
  if (head && head.fork === true) {
    return true;
  }
  return Boolean(head && base && head.full_name && base.full_name && head.full_name !== base.full_name);
}

// Posts the comment and returns its URL, or undefined when no comment was posted.
async function postComment({ github, context, core }, env = process.env) {
  const pullRequest = context.payload && context.payload.pull_request;
  if (!pullRequest || !pullRequest.number) {
    core.info('Not a pull request: no comment to post.');
    return undefined;
  }

  const reportFile = env.PHP_LINT_REPORT_FILE;
  let report;
  try {
    report = fs.readFileSync(reportFile, 'utf8');
  } catch (error) {
    core.warning(`Could not read the PHP Lint report '${reportFile}', so no comment was posted: ${error.message}`);
    return undefined;
  }

  const commentMarker = marker(env.PHP_LINT_COMMENT_KEY);
  const runUrl =
    context.serverUrl && context.runId
      ? `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`
      : '';
  const body = buildBody({ marker: commentMarker, report, runUrl });
  const target = { owner: context.repo.owner, repo: context.repo.repo, issue_number: pullRequest.number };

  try {
    const existing = await findComment(github, target, commentMarker);
    if (existing) {
      const { data } = await github.rest.issues.updateComment({
        owner: target.owner,
        repo: target.repo,
        comment_id: existing.id,
        body,
      });
      core.info(`Updated the comment on pull request #${pullRequest.number}: ${data.html_url}`);
      return data.html_url;
    }
    const { data } = await github.rest.issues.createComment({ ...target, body });
    core.info(`Posted a comment on pull request #${pullRequest.number}: ${data.html_url}`);
    return data.html_url;
  } catch (error) {
    const status = error.status ? ` (HTTP ${error.status})` : '';
    const fromFork = isFromFork(pullRequest);
    const fromDependabot = context.actor === 'dependabot[bot]';
    let hint;
    if (fromFork) {
      hint = 'The GITHUB_TOKEN is read-only on pull requests from forks, so the comment cannot be posted there.';
    } else if (fromDependabot) {
      hint =
        "The GITHUB_TOKEN is read-only on Dependabot's pull requests unless the workflow runs on pull_request_target, " +
        'so the comment cannot be posted there.';
    } else {
      hint =
        "The token needs the 'pull-requests: write' permission to comment on the pull request; " +
        "set 'comment: false' to turn the comment off.";
    }
    const message = `Could not post the PHP Lint comment on pull request #${pullRequest.number}${status}: ${error.message}. ${hint}`;
    if (fromFork || fromDependabot) {
      core.info(message);
    } else {
      core.warning(message);
    }
    return undefined;
  }
}

module.exports = postComment;
module.exports.buildBody = buildBody;
module.exports.marker = marker;
module.exports.MAX_BODY_LENGTH = MAX_BODY_LENGTH;
