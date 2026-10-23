#!/usr/bin/env bash
# PostToolUse (Bash): after a successful `gh pr create`, auto-request a Copilot
# review on the new PR — but only when the PR is worth a review.
#
# Copilot is a bot — `gh pr edit --add-reviewer` and GraphQL requestReviews both
# reject it. The only working path is the REST requested_reviewers endpoint with
# the `copilot-pull-request-reviewer[bot]` login (the `[bot]` suffix is
# required). See AGENTS.md.
#
# matcher:Bash fires this on EVERY Bash call — Claude Code has no per-hook
# command filter — so the script self-gates on `gh pr create` (mirroring
# pre-commit-reminder.sh's `git commit` gate) and no-ops on everything else.
#
# Gates (all must pass to auto-request):
#   1. Real product-code change: PRs that touch only documentation (*.md, docs/,
#      README/LICENSE/… ) or repo tooling/meta (.claude/, .github/) are skipped —
#      Copilot review adds no value there.
#   2. Significance: >50 changed code lines auto-requests. At or below 50 the
#      script does NOT auto-request; instead it hands the decision to the agent
#      via additionalContext ("request manually if this is a major change").
#   3. Once per PR: if Copilot is already a requested reviewer or has already
#      submitted a review, skip — never re-request.

# No `set -e`: a hook must never hard-fail on malformed input. Every extraction
# is guarded and the script always exits 0.

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Self-gate: only act on `gh pr create`. The `-[^ ]+( value)?` groups tolerate
# global/sub options between the tokens, e.g. `gh -R owner/repo pr create`,
# `gh pr create --fill`. A bare non-flag token between `pr` and `create` (e.g.
# `gh pr list && echo create`) does NOT match. The boundary classes include `(`
# and `)` so a create inside a command substitution or subshell —
# `pr_url=$(gh pr create --fill)` — is still recognized.
gate='(^|[[:space:];&|(])gh([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+pr([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+create([[:space:];&|)]|$)'
if ! printf '%s' "$command" | grep -qE "$gate"; then
  exit 0
fi

# `gh pr create` prints the new PR URL on stdout; pull it from the tool response.
pr_url=$(printf '%s' "$input" | grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | head -n1 || true)
if [ -z "$pr_url" ]; then
  # No URL => the create didn't succeed (or output format changed). Surface it
  # rather than silently skipping.
  echo "pr-add-copilot-reviewer: no PR URL in gh output; Copilot NOT requested" >&2
  exit 0
fi

rest=${pr_url#https://github.com/}
owner=$(printf '%s' "$rest" | cut -d/ -f1)
repo=$(printf '%s' "$rest" | cut -d/ -f2)
number=$(printf '%s' "$rest" | cut -d/ -f4)

if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$number" ]; then
  echo "pr-add-copilot-reviewer: could not parse owner/repo/number from ${pr_url}; Copilot NOT requested" >&2
  exit 0
fi

# Gate 3 (first, cheapest): skip if Copilot was already requested or has already
# reviewed. Keeps the request to exactly once per PR even if the hook re-fires.
already_requested=$(gh api "repos/${owner}/${repo}/pulls/${number}/requested_reviewers" 2>/dev/null \
  | jq -r 'any((.users // [])[]; (.login // "") | ascii_downcase | test("copilot"))' 2>/dev/null || true)
already_reviewed=$(gh api --paginate "repos/${owner}/${repo}/pulls/${number}/reviews" 2>/dev/null \
  | jq -s -r 'any((add // [])[]; (.user.login // "") | ascii_downcase | test("copilot"))' 2>/dev/null || true)
if [ "$already_requested" = "true" ] || [ "$already_reviewed" = "true" ]; then
  echo "pr-add-copilot-reviewer: Copilot already requested/reviewed on ${pr_url}; skipping" >&2
  exit 0
fi

# Gates 1 & 2: classify the diff. Pull per-file additions/deletions and drop
# documentation files; what remains is "code". `--paginate` may emit several
# JSON arrays, so `jq -s add` flattens them into one list.
files_json=$(gh api --paginate "repos/${owner}/${repo}/pulls/${number}/files" 2>/dev/null || true)
code_stats=$(printf '%s' "$files_json" | jq -s '
  (add // [])
  | map(select(
      (
        (.filename | test("\\.(md|markdown|mdx|rst|txt|adoc)$"; "i"))
        or (.filename | test("(^|/)(README|CHANGELOG|CHANGES|LICENSE|NOTICE|CONTRIBUTING|AGENTS|CODEOWNERS)[^/]*$"; "i"))
        or (.filename | test("(^|/)docs/"; "i"))
        or (.filename | test("(^|/)\\.(claude|github)/"; "i"))
      ) | not
    ))
  | {files: length, changes: (map((.additions // 0) + (.deletions // 0)) | add // 0)}
' 2>/dev/null || true)

code_files=$(printf '%s' "$code_stats" | jq -r '.files // 0' 2>/dev/null || echo 0)
code_changes=$(printf '%s' "$code_stats" | jq -r '.changes // 0' 2>/dev/null || echo 0)
[ -z "$code_files" ] && code_files=0
[ -z "$code_changes" ] && code_changes=0

# Gate 1: no product-code files touched (doc/tooling-only) => never request.
if [ "$code_files" -eq 0 ] 2>/dev/null; then
  echo "pr-add-copilot-reviewer: doc/tooling-only change on ${pr_url}; Copilot NOT requested" >&2
  exit 0
fi

# Gate 2: at or below the line threshold, defer to the agent's judgment instead
# of auto-requesting. Emit additionalContext so the agent can request Copilot
# manually when it considers the change major.
THRESHOLD=50
if [ "$code_changes" -le "$THRESHOLD" ] 2>/dev/null; then
  jq -n --arg pr "$pr_url" --arg n "$code_changes" --arg owner "$owner" --arg repo "$repo" --arg num "$number" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("Copilot review NOT auto-requested on " + $pr + ": only " + $n + " code lines changed (<=50). If you judge this a MAJOR change, request a Copilot review manually:\n  gh api -X POST repos/" + $owner + "/" + $repo + "/pulls/" + $num + "/requested_reviewers -f \"reviewers[]=copilot-pull-request-reviewer[bot]\"")
    }
  }' 2>/dev/null || true
  exit 0
fi

# Both gates passed and the change is significant (>50 code lines): auto-request.
if gh api -X POST "repos/${owner}/${repo}/pulls/${number}/requested_reviewers" \
     -f "reviewers[]=copilot-pull-request-reviewer[bot]" >/dev/null 2>&1; then
  jq -n --arg pr "$pr_url" --arg n "$code_changes" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("Copilot review auto-requested on " + $pr + " (" + $n + " code lines changed)")
    }
  }' 2>/dev/null || true
else
  echo "pr-add-copilot-reviewer: FAILED to request Copilot review on ${pr_url} (check gh auth / repo Copilot access)" >&2
fi

exit 0
