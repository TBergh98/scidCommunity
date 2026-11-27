#!/bin/sh
# Cloud sessions: give the checkout the same notes layout as my PCs.
# The environment's setup script runs, from the checkout root:
#   git fetch -q origin claude-notes && git show FETCH_HEAD:cloud-setup.sh | sh
# Result: ../scidCommunity-notes is a worktree of claude-notes (all notes
# files, pushable), and CLAUDE.md in the checkout is a symlink to it.
set -e
git fetch -q origin claude-notes:refs/remotes/origin/claude-notes
notes=../scidCommunity-notes
# single-branch clones refuse --set-upstream-to here, so write the tracking config directly
git config branch.claude-notes.remote origin
git config branch.claude-notes.merge refs/heads/claude-notes
if [ -e "$notes/.git" ]; then
  git -C "$notes" pull -q --ff-only
else
  git worktree add -q --no-track -B claude-notes "$notes" origin/claude-notes
fi
ln -sfn "$notes/CLAUDE.md" CLAUDE.md
exclude=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"
grep -qx '/CLAUDE.md' "$exclude" 2>/dev/null || echo '/CLAUDE.md' >> "$exclude"
