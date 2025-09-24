# Upstream Sync Guidance

This fork tracks `vllm-project/vllm` upstream. Automation lives in `.github/workflows/sync_with_upstream.yml` and this `extras/ci` directory gives you manual tooling & templates while keeping fork-specific additions isolated under `extras/`.

## Goals
- Keep `main` reasonably aligned with upstream while preserving fork patches in `extras/`.
- Prefer **fast-forward** when no local-only commits exist on `main`.
- Fall back to merge (or optional rebase) when local divergence is present.
- Surface conflicts early with artifacts & issues.

## Manual Sync (Local)
```bash
# From repo root
bash extras/ci/sync_upstream.sh            # default upstream main
bash extras/ci/sync_upstream.sh vllm-project/vllm release-0.6  # different branch
# Push if satisfied
git push origin main
```

## GitHub Workflow Overview
Workflow: `.github/workflows/sync_with_upstream.yml`

Features:
- Scheduled daily run (00:00 UTC) + manual `workflow_dispatch` with inputs:
  - `strategy`: `merge` (default) | `rebase` | `ff-only`
  - `upstream_ref`: override branch/ref (e.g. `upstream/release-0.6`)
- Tag + branch fetch with prune to reflect upstream deletion.
- Divergence detection & fast-forward attempt.
- Automatic fallback merge (or rebase if selected; merges if rebase conflicts).
- Workflow file change detection -> opens PR instead of direct push.
- Conflict handling: new branch + issue + artifact upload (`conflict-diff.patch`, `conflict-status.txt`).

## Recommended Cron Strategy
Daily is usually sufficient. If upstream is very active and you want smaller conflict windows, use every 6 hours:
```
0 */6 * * *
```

## Protected Branch Considerations
If `main` is protected against direct pushes, either:
1. Allow GitHub Actions bot to bypass (Branch protection setting), or
2. Always create PRs even for non-workflow syncs (modify push step condition to open PR unconditionally).

## Rebase Mode Caveat
`rebase` rewrites history. Only use if you are certain no one depends on fork-specific merge commits. The workflow already falls back to merge if rebase conflicts.

## Conflict Resolution Flow
1. Checkout conflict branch announced in issue:
   ```bash
   git fetch origin
   git checkout <conflict-branch>
   ```
2. Inspect artifacts from workflow run for quick context.
3. Resolve conflicts, continue merge/rebase, push branch, open PR (or fast-forward main if safe).

## Customizing Upstream Repo
To switch upstream source permanently, edit the `UPSTREAM_REPO` env in the workflow. For ephemeral runs use `workflow_dispatch` input `upstream_ref`.

## Dry-Run Strategy (Preview Only)
Add a job-level conditional or an additional input (`dry_run: true`) and replace the push/PR steps with echo statements. Not included by default to keep workflow concise.

## Future Enhancements (Optional)
- Auto-label sync PRs (add a `labels:` field in the PR step).
- Slack / Teams notification on conflict (add webhook action).
- Auto-close stale conflict branches after resolution.

## Quick Reference
| Action | Command |
|--------|---------|
| Fast-forward only attempt | `git merge --ff-only upstream/main` |
| Show divergence counts | `git rev-list --count upstream/main..main` / `git rev-list --count main..upstream/main` |
| Rebase manually | `git rebase upstream/main` |
| Abort failed rebase | `git rebase --abort` |
| Create conflict diff patch | `git diff > conflict-diff.patch` |

---
All automation outside upstream code paths lives in `extras/`. Adjust / remove locally without disturbing core upstream alignment.
