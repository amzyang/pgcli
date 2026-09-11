#!/usr/bin/env fish
if test (git branch --show-current) != master
    echo "Error: sync.sh must run on the master branch"
    exit 1
end

git fetch origin; or exit 1
# tags come from upstream only; --tags against both remotes can clobber each other
git fetch --tags upstream; or exit 1

# pre-rebase checks
if not git diff --quiet; or not git diff --cached --quiet
    echo "Error: working tree is not clean, commit or stash changes first"
    exit 1
end

if not git rev-parse --verify upstream/main >/dev/null 2>&1
    echo "Error: upstream/main not found"
    exit 1
end

if test -d (git rev-parse --git-dir)/rebase-merge; or test -d (git rev-parse --git-dir)/rebase-apply
    echo "Error: a rebase is already in progress"
    exit 1
end

git rebase upstream/main
if test $status -ne 0
    echo "Rebase hit conflicts, invoking Claude to resolve..."
    set -l resolve_prompt '/goal A rebase onto upstream/main is in progress and paused on conflicts. Resolve the conflicts and run git rebase --continue, repeating until the rebase is complete.

Conflict resolution rules, learned from the 2026-08-02 mycli incident:
- This branch is a patch stack on top of upstream/main. For each conflict, recover the intent of the commit being replayed (git show it) and preserve its pre-rebase behavior. Do not mechanically keep both sides.
- Never keep the same argument, import, or line from both sides. That is exactly how the incident happened: the resolution kept a cursor= keyword argument from each side of one PromptSession call, producing a SyntaxError that broke even the --help entry point.
- When upstream adds code whose behavior a patch already covers or deliberately overrides, keep the patch line and drop the upstream one.
- Before every git rebase --continue, run: python3 -m compileall -q pgcli
  If it fails, fix the resolution before continuing, so every replayed commit at least parses and the stack stays bisectable.'
    claude -p --dangerously-skip-permissions $resolve_prompt

    # verify the rebase actually completed before pushing
    if test -d (git rev-parse --git-dir)/rebase-merge; or test -d (git rev-parse --git-dir)/rebase-apply
        echo "Error: rebase still in progress after Claude, aborting..."
        git rebase --abort
        exit 1
    end
end

# catches the case where Claude aborted the rebase instead of completing it
if not git merge-base --is-ancestor upstream/main HEAD
    echo "Error: HEAD does not contain upstream/main, rebase did not complete"
    exit 1
end

# smoke: auto-resolved conflicts must at least byte-compile before anything ships
if not python3 -m compileall -q pgcli
    echo "Error: source fails to compile after rebase, not pushing"
    exit 1
end

git push --force-with-lease; or exit 1
# keep fork tags current, otherwise setuptools-scm versions the pip build off a stale tag
git push origin --tags; or exit 1

# converge uv tool state: pgcli at HEAD with catppuccin[pygments]
# the version string drops the +g<sha> suffix when HEAD sits exactly on a tag, so compare the
# commit recorded by the installer (PEP 610 direct_url.json) instead; -I keeps the repo's own
# *.egg-info in the cwd from shadowing the installed distribution
set -l installed_commit (~/.local/share/uv/tools/pgcli/bin/python -I -c "from importlib.metadata import distribution; import json; print(json.loads(distribution('pgcli').read_text('direct_url.json'))['vcs_info']['commit_id'])" 2>/dev/null)
set -l spec 'pgcli @ git+https://github.com/amzyang/pgcli'
if test "$installed_commit" = (git rev-parse HEAD)
    echo "pgcli already at $installed_commit, skipping reinstall"
else
    # --reinstall implies --refresh, so the unpinned git ref is re-resolved to the pushed HEAD;
    # --force lets a changed spec (extras / --with) replace the existing receipt instead of erroring
    uv tool install --force --reinstall $spec --with 'catppuccin[pygments]'; or exit 1
end

# smoke: the installed CLI must survive its import chain end to end
if not ~/.local/bin/pgcli --help >/dev/null
    echo "Error: installed pgcli fails --help smoke check"
    exit 1
end
