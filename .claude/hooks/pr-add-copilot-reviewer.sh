#!/usr/bin/env bash
# PostToolUse (Bash): after a successful `gh pr create`, auto-request a Copilot
# review on the new PR.
#
# Copilot is a bot — `gh pr edit --add-reviewer` and GraphQL requestReviews both
# reject it. The only working path is the REST requested_reviewers endpoint with
# the `copilot-pull-request-reviewer[bot]` login (the `[bot]` suffix is
# required). See AGENTS.md.
#
# matcher:Bash fires this on EVERY Bash call — Claude Code has no per-hook
# command filter — so the script self-gates on `gh pr create` (mirroring
# pre-commit-reminder.sh's `git commit` gate) and no-ops on everything else.

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

if gh api -X POST "repos/${owner}/${repo}/pulls/${number}/requested_reviewers" \
     -f "reviewers[]=copilot-pull-request-reviewer[bot]" >/dev/null 2>&1; then
  jq -n --arg pr "$pr_url" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("Copilot review auto-requested on " + $pr)
    }
  }' 2>/dev/null || true
else
  echo "pr-add-copilot-reviewer: FAILED to request Copilot review on ${pr_url} (check gh auth / repo Copilot access)" >&2
fi

exit 0
