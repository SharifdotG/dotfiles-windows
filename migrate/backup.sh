#!/usr/bin/env bash
# Back up, into one folder, what a fresh Windows install can't get back from git
# or an installer. Run it on CachyOS before the wipe; put it back on Windows with
# migrate\restore.ps1 (docs/SETUP.md, stages 0 and 4).
#
# The Linux repo's own tools do the parts they already get right:
#   db-backup.sh      every Postgres database as pg_dump -Fc - one per database,
#                     not one per server - and the other named volumes as tarballs
#   agents-backup.sh  global MCP servers, skills, settings, rules, plugin lists
# This script adds what they leave out:
#   projects/  per project: the files git doesn't carry (ignored or untracked,
#              without rebuildable folders such as node_modules), and the remote
#              and branch restore.ps1 clones from
#   claude/    Claude Code transcripts, auto-memory, plans, prompt history and
#              rewind checkpoints; Claude Desktop's Code-tab session list
#
# Left out on purpose: ~/.claude/.credentials.json (sign in again - a live token
# doesn't belong in a backup), Claude Desktop's 12 GB vm_bundles (downloaded
# again), and node_modules/.venv (Linux binaries that won't run on Windows).
#
# THE OUTPUT HOLDS SECRETS: .env files, MCP API keys and bearer tokens, role
# password hashes. It is created 0700. Keep it off every repo, and in two places.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
LINUX_REPO="${DOTFILES_LINUX:-$HOME/dotfiles}"
[ -x "$LINUX_REPO/scripts/db-backup.sh" ] || LINUX_REPO="$REPO/dotfiles-linux"
CODE_ROOT="${CODE_ROOT:-$HOME/Documents/Code}"
OUT_ROOT="$HOME/Backup/windows-migration"
PROJECTS=()
WARNINGS=0

usage() {
  cat <<'EOS'
usage: migrate/backup.sh [-o DIR] [-p PROJECT]...

  -o, --out DIR        parent folder (default ~/Backup/windows-migration). Each run
                       creates a new timestamped folder inside it.
  -p, --project NAME   a folder under ~/Documents/Code. Repeatable, and replaces the
                       default list: SocialHousingOSS and structflow.

Environment: DOTFILES_LINUX (default ~/dotfiles), CODE_ROOT (default ~/Documents/Code)
EOS
  exit "${1:-0}"
}
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)     [ -n "${2:-}" ] || usage 1; OUT_ROOT="$2"; shift 2 ;;
    -p|--project) [ -n "${2:-}" ] || usage 1; PROJECTS+=("$2"); shift 2 ;;
    -h|--help)    usage 0 ;;
    *)            printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done
[ "${#PROJECTS[@]}" -gt 0 ] || PROJECTS=(SocialHousingOSS structflow)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. preflight -------------------------------------------------------------
say "Preflight"
command -v jq >/dev/null || die "jq is required"
{ command -v docker >/dev/null && docker info >/dev/null 2>&1; } || die "cannot reach the docker daemon - the databases live there"
for s in db-backup.sh agents-backup.sh; do
  [ -x "$LINUX_REPO/scripts/$s" ] || die "$LINUX_REPO/scripts/$s not found - set DOTFILES_LINUX to the Linux dotfiles checkout"
done
ok "Linux tools: $LINUX_REPO/scripts"
for p in "${PROJECTS[@]}"; do
  [ -d "$CODE_ROOT/$p/.git" ] || die "$CODE_ROOT/$p is not a git checkout"
done
ok "projects: ${PROJECTS[*]}"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUT_ROOT/$STAMP"
(umask 077 && mkdir -p "$OUT/projects" "$OUT/claude") || die "cannot create $OUT"
chmod 700 "$OUT_ROOT" "$OUT"
ok "writing $OUT"

# ---- 2. projects --------------------------------------------------------------
say "Projects: git state, and the files git doesn't carry"
# Rebuilt on Windows anyway, or Linux binaries that wouldn't run there.
REBUILDABLE='(^|/)(node_modules|\.venv[^/]*|venv|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.hypothesis|\.jest-cache|test-results|coverage|dist|bin|obj|\.nx|\.angular|\.turbo|\.cache)(/|$)|\.pyc$'
printf '# name\tremote\tbranch\tcommit\n' > "$OUT/projects/projects.tsv"
for p in "${PROJECTS[@]}"; do
  dir="$CODE_ROOT/$p"
  printf '%s\t%s\t%s\t%s\n' "$p" "$(git -C "$dir" remote get-url origin 2>/dev/null)" \
    "$(git -C "$dir" branch --show-current)" "$(git -C "$dir" rev-parse HEAD)" >> "$OUT/projects/projects.tsv"

  # Untracked files are archived below. Edits to TRACKED files, unpushed commits
  # and stashes are not - the remote is their backup - so name them now.
  changed=$(git -C "$dir" status --porcelain --untracked-files=no | wc -l)
  [ "$changed" -eq 0 ] || warn "$p: $changed tracked file(s) with uncommitted changes - commit and push them"
  while read -r ref up track; do
    if [ -z "$up" ]; then warn "$p: branch $ref has no upstream - push it"
    else case "$track" in *ahead*) warn "$p: branch $ref is $track against $up - push it" ;; esac
    fi
  done < <(git -C "$dir" for-each-ref --format='%(refname:short) %(upstream:short) %(upstream:track)' refs/heads)
  [ "$(git -C "$dir" stash list | wc -l)" -eq 0 ] || warn "$p: has stashes - they are not in this backup"

  list="$OUT/projects/$p.files"
  ( cd "$dir" && { git ls-files --others --exclude-standard; git ls-files --others --ignored --exclude-standard; } ) |
    grep -Ev "$REBUILDABLE" | sort -u > "$list"
  if [ ! -s "$list" ]; then
    ok "$p: nothing outside git"
  elif (umask 077 && tar -czf "$OUT/projects/$p.tar.gz" -C "$dir" --verbatim-files-from -T "$list"); then
    ok "$p: $(wc -l < "$list") local-only file(s) -> projects/$p.tar.gz"
    sed 's/^/            /' "$list" | head -25
  else
    warn "$p: could not archive its local-only files"
  fi
done

# ---- 3. databases and volumes -------------------------------------------------
say "Databases and volumes (db-backup.sh)"
printf '    Containers using a volume are stopped while it is copied, then started again.\n'
"$LINUX_REPO/scripts/db-backup.sh" -o "$OUT/db" || warn "db-backup.sh exited with $? - read its output above"

# ---- 4. MCP servers, skills, settings -----------------------------------------
say "MCP servers, skills and Claude settings (agents-backup.sh export)"
"$LINUX_REPO/scripts/agents-backup.sh" export -o "$OUT/agents" || warn "agents-backup.sh exited with $?"

# ---- 5. sessions --------------------------------------------------------------
say "Claude Code sessions, and Claude Desktop's session list"
# GNU tar exits 1 when a file changed while it was read - normal for the
# transcript of a session that is still open. Only 2 is a failure.
archive() { # archive <out> <dir> <entry>...
  local out="$1" dir="$2" e rc; shift 2
  local have=()
  for e in "$@"; do [ -e "$dir/$e" ] && have+=("$e"); done
  if [ "${#have[@]}" -eq 0 ]; then warn "nothing to archive in $dir"; return; fi
  (umask 077 && tar -czf "$out" -C "$dir" "${have[@]}"); rc=$?
  if [ "$rc" -le 1 ]; then ok "$(basename "$out")  $(du -h "$out" | cut -f1)  (${have[*]})"
  else warn "$(basename "$out"): tar failed ($rc)"; fi
}
archive "$OUT/claude/claude-code.tar.gz"    "$HOME/.claude"        projects plans file-history history.jsonl
archive "$OUT/claude/claude-desktop.tar.gz" "$HOME/.config/Claude" claude-code-sessions local-agent-mode-sessions
ok "$(find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | wc -l) transcript(s) across $(find "$HOME/.claude/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) project folder(s)"

# ---- 6. manifest and checksums ------------------------------------------------
say "Manifest and checksums"
# restore.ps1 maps every path under codeRoot to the same path under D:\Code.
jq -n --arg taken "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg home "$HOME" --arg codeRoot "$CODE_ROOT" \
  '{taken: $taken, home: $home, codeRoot: $codeRoot, projects: $ARGS.positional}' \
  --args "${PROJECTS[@]}" > "$OUT/manifest.json" || warn "could not write manifest.json"
if (cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS); then
  ok "SHA256SUMS: $(wc -l < "$OUT/SHA256SUMS") file(s)"
else
  warn "could not write SHA256SUMS"
fi

say "Done: $OUT  ($(du -sh "$OUT" | cut -f1))"
[ "$WARNINGS" -eq 0 ] || printf '    \033[33m%s warning(s) above - read them before you wipe anything.\033[0m\n' "$WARNINGS"
cat <<EOS
    - It holds secrets. Copy the whole folder to a drive that survives the wipe, and to one more place.
    - Kept working after this? Run it again right before the wipe; each run is a new folder.
    - On Windows (docs/SETUP.md, stage 4):
        pwsh -File .\\migrate\\restore.ps1 -Backup <where you copied it>\\$STAMP
EOS
exit $((WARNINGS > 0))
