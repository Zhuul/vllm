#!/usr/bin/env bash
set -euo pipefail

# Simple manual upstream sync helper (run locally or in container)
# Usage: extras/ci/sync_upstream.sh [upstream_repo] [branch]
# Defaults: upstream_repo=vllm-project/vllm branch=main

UPSTREAM_REPO="${1:-vllm-project/vllm}"
BRANCH="${2:-main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[sync] Not inside a git repository" >&2
  exit 1
fi

echo "[sync] Ensuring upstream remote exists -> $UPSTREAM_REPO"
if ! git remote | grep -q '^upstream$'; then
  git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"
fi

echo "[sync] Fetching upstream branches & tags"
git fetch --tags --prune upstream "+refs/heads/*:refs/remotes/upstream/*"

# Ensure local branch exists
if ! git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  echo "[sync] Local branch ${BRANCH} does not exist. Creating tracking from origin/${BRANCH}" >&2
  git checkout -b "${BRANCH}" "origin/${BRANCH}" || true
fi

echo "[sync] Checkout ${BRANCH}"
git checkout "${BRANCH}"

UPSTREAM_REF="upstream/${BRANCH}"
if ! git show-ref --verify --quiet "refs/remotes/${UPSTREAM_REF}"; then
  echo "[sync] Upstream ref ${UPSTREAM_REF} not found" >&2
  exit 1
fi

echo "[sync] Calculating divergence"
BASE=$(git merge-base "${BRANCH}" "${UPSTREAM_REF}")
AHEAD_LOCAL=$(git rev-list --count "${UPSTREAM_REF}".."${BRANCH}")
AHEAD_UPSTREAM=$(git rev-list --count "${BRANCH}".."${UPSTREAM_REF}")
echo "[sync] Local ahead: ${AHEAD_LOCAL} | Upstream ahead: ${AHEAD_UPSTREAM}"

if [ "${AHEAD_LOCAL}" = 0 ]; then
  echo "[sync] Attempting fast-forward"
  git merge --ff-only "${UPSTREAM_REF}" && {
    echo "[sync] Fast-forward complete"; exit 0; }
fi

echo "[sync] Performing merge"
if git merge --no-edit "${UPSTREAM_REF}"; then
  echo "[sync] Merge complete"
else
  echo "[sync] Merge conflict encountered. Leaving state for manual resolution." >&2
  exit 2
fi

