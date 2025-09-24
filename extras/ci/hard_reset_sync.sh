#!/usr/bin/env bash
set -euo pipefail

# Hard reset fork main to upstream/main and reapply extras + workflow.
# Safe usage: run from repo root on a clean working tree.
# Creates backup branch: backup/pre-hard-reset-<timestamp>

UPSTREAM=${UPSTREAM_REMOTE:-upstream}
UPSTREAM_REPO=${UPSTREAM_REPO:-vllm-project/vllm}
FORK_BRANCH=${FORK_BRANCH:-main}
UPSTREAM_BRANCH=${UPSTREAM_BRANCH:-main}
WORKFLOW_FILE=.github/workflows/sync_with_upstream.yml

if ! git remote | grep -q "^${UPSTREAM}$"; then
  git remote add "$UPSTREAM" "https://github.com/${UPSTREAM_REPO}.git"
fi

git fetch "$UPSTREAM" --prune

if [ -n "$(git status --porcelain)" ]; then
  echo "[hard-reset-sync] Working tree not clean. Commit or stash first." >&2
  exit 1
fi

git checkout "$FORK_BRANCH"
TS=$(date +%Y%m%d%H%M%S)
BACKUP=backup/pre-hard-reset-$TS
git branch "$BACKUP"
echo "[hard-reset-sync] Created backup branch $BACKUP"

git reset --hard "$UPSTREAM/$UPSTREAM_BRANCH"

git checkout "$BACKUP" -- extras "$WORKFLOW_FILE" || true

git add extras "$WORKFLOW_FILE"
if [ -f extras/patches/apply_patches.sh ]; then
  bash extras/patches/apply_patches.sh || echo "[hard-reset-sync] Patch script exited non-zero; continuing"
  # Re-stage any modified upstream files ONLY if you explicitly want them; we avoid this to keep clean baseline.
  git checkout "$UPSTREAM/$UPSTREAM_BRANCH" -- $(git diff --name-only --cached | grep -v '^extras/' | grep -v "^$WORKFLOW_FILE" || true)
fi

git commit -m "fork(base): hard reset to upstream/${UPSTREAM_BRANCH} + extras & workflow"

echo "[hard-reset-sync] Force pushing $FORK_BRANCH"
git push origin "$FORK_BRANCH" --force

echo "[hard-reset-sync] Done. Backup at $BACKUP"
