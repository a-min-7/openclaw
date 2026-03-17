#!/usr/bin/env bash
# update-upstream.sh — Pull latest stable upstream tag, rebuild, and restart the local Ollama stack.
#
# Usage:
#   ./scripts/update-upstream.sh            # full update
#   ./scripts/update-upstream.sh --dry-run  # print what would happen, exit 0
#
# Assumptions:
#   - Remote "upstream" points to https://github.com/openclaw/openclaw
#   - Remote "origin"   points to https://github.com/a-min-7/openclaw
#   - Stack runs via Podman Compose with .env in repo root
#   - Known local-only files: AGENTS.md, CLAUDE.md, docker-compose.yml, scripts/update-upstream.sh

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$SCRIPT_DIR/update.log"
BRANCH="local/ollama-setup"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"

_log() {
  local level="$1"; shift
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts] $level $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line"
}

info()  { _log "${GREEN}INFO ${RESET}" "$@"; }
warn()  { _log "${YELLOW}WARN ${RESET}" "$@"; }
error() { _log "${RED}ERROR${RESET}" "$@"; }
die()   { error "$@"; exit 1; }
step()  { _log "${BOLD}STEP ${RESET}" "$@"; }

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) die "Unknown argument: $arg  (accepted: --dry-run)" ;;
  esac
done

cd "$REPO_ROOT"
info "Starting update-upstream  (dry-run: $DRY_RUN)  log: $LOG_FILE"

# ── 1. Dependency checks ──────────────────────────────────────────────────────
step "1/10  Checking required tools"
for cmd in git podman curl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    info "  ✓ $cmd  ($(command -v "$cmd"))"
  else
    die "Required tool not found: $cmd"
  fi
done

# ── 2. Fetch upstream tags ────────────────────────────────────────────────────
step "2/10  Fetching upstream tags"
git fetch upstream --tags --quiet 2>>"$LOG_FILE" \
  || die "git fetch upstream failed — is the 'upstream' remote configured?"
info "  ✓ upstream fetched"

# ── 3. Determine latest stable tag and current base ───────────────────────────
step "3/10  Comparing tags"

# Stable tag: vYYYY.M.D or vYYYY.M.D-N — no beta, rc, alpha, or named suffixes
latest_tag=$(
  git tag -l 'v[0-9]*.[0-9]*.[0-9]*' \
    | grep -E '^v[0-9]{4}\.[0-9]+\.[0-9]+(-[0-9]+)?$' \
    | sort -V \
    | tail -1 \
  || true
)
[[ -n "$latest_tag" ]] || die "No stable upstream tags found matching vYYYY.M.D"
info "  Latest stable tag : $latest_tag"

# Current base: nearest ancestor stable tag.
# --abbrev=0 always returns just the tag name, even when HEAD has commits on top
# (e.g. v2026.3.12-3-gfe1b9a6 is never produced — we get v2026.3.12 cleanly).
current_tag=$(
  git describe --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 HEAD 2>/dev/null \
  || echo "unknown"
)
info "  Current base tag  : $current_tag"

# ── 4. Up-to-date check ───────────────────────────────────────────────────────
if [[ "$current_tag" == "$latest_tag" ]]; then
  info "${GREEN}${BOLD}Already up to date${RESET} ($current_tag)"
  exit 0
fi
info "  Update available  : $current_tag → $latest_tag"

# ── 5. Pre-flight sanity checks ───────────────────────────────────────────────
step "4/10  Pre-flight checks"

# Load .env to read OLLAMA_BASE_URL
[[ -f .env ]] || die ".env not found in repo root"
OLLAMA_BASE_URL=$(grep -E '^OLLAMA_BASE_URL=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
[[ -n "$OLLAMA_BASE_URL" ]] || die "OLLAMA_BASE_URL not set in .env"
info "  Ollama URL: $OLLAMA_BASE_URL"

# Ollama reachable
if curl -sf --max-time 5 "${OLLAMA_BASE_URL}/api/tags" >>"$LOG_FILE" 2>&1; then
  info "  ✓ Ollama reachable"
else
  die "Ollama not reachable at $OLLAMA_BASE_URL — is the LAN model server running?"
fi

# Gateway healthy (warning only — stack may not be running before a first-time update)
if curl -sf --max-time 5 "http://localhost:18789/healthz" >>"$LOG_FILE" 2>&1; then
  info "  ✓ Gateway healthy"
else
  warn "  Gateway not responding at localhost:18789/healthz — stack may not be running (continuing)"
fi

# Working tree clean except for known local files
KNOWN_LOCAL_FILES=("AGENTS.md" "CLAUDE.md" "docker-compose.yml" "scripts/update-upstream.sh")
unexpected_dirty=()
while IFS= read -r status_line; do
  [[ -z "$status_line" ]] && continue
  # porcelain v1: "XY path" or "XY orig -> path"
  file="${status_line:3}"
  # strip rename arrow (git mv shows "old -> new"; take the destination)
  file="${file##* -> }"
  known=false
  for kf in "${KNOWN_LOCAL_FILES[@]}"; do
    [[ "$file" == "$kf" ]] && known=true && break
  done
  $known || unexpected_dirty+=("$file")
done < <(git status --porcelain)

if [[ ${#unexpected_dirty[@]} -gt 0 ]]; then
  error "Unexpected uncommitted changes:"
  for f in "${unexpected_dirty[@]}"; do error "  $f"; done
  die "Commit or stash the above files before running this script"
fi
info "  ✓ Working tree clean (only expected local files may be modified)"

# ── 6. Dry-run ────────────────────────────────────────────────────────────────
if $DRY_RUN; then
  info ""
  info "${BOLD}[DRY RUN] — no changes will be made${RESET}"
  info ""
  info "  Would update $current_tag → $latest_tag:"
  info "    1. Save AGENTS.md, CLAUDE.md, docker-compose.yml, scripts/update-upstream.sh to temp dir"
  info "    2. git checkout $latest_tag"
  info "    3. Restore saved local files"
  info "    4. git checkout -B $BRANCH"
  info "    5. podman build --build-arg NODE_OPTIONS=--max-old-space-size=4096 -t openclaw:local -f Dockerfile ."
  info "    6. podman compose --env-file .env down --remove-orphans --timeout 10"
  info "    7. podman compose --env-file .env up -d openclaw-gateway"
  info "    8. Wait up to 30s for /healthz"
  info "    9. git add AGENTS.md CLAUDE.md docker-compose.yml scripts/update-upstream.sh && git commit -m 'chore: update to $latest_tag'"
  info "   10. git push --force-with-lease origin $BRANCH"
  exit 0
fi

# ── 7. Rebase onto new tag (preserve local files) ─────────────────────────────
step "5/10  Rebasing onto $latest_tag"

TMP_DIR=$(mktemp -d)

# Capture current branch HEAD so we can roll back if anything fails mid-update.
ROLLBACK_SHA=$(git rev-parse HEAD 2>/dev/null || true)
ROLLBACK_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)

_rollback() {
  local exit_code=$?
  rm -rf "$TMP_DIR"
  if [[ $exit_code -ne 0 && -n "${ROLLBACK_SHA:-}" ]]; then
    error "Update failed (exit $exit_code) — rolling back to $ROLLBACK_SHA"
    if [[ -n "${ROLLBACK_BRANCH:-}" ]]; then
      git checkout -B "$ROLLBACK_BRANCH" "$ROLLBACK_SHA" 2>>"$LOG_FILE" \
        && warn "  Rolled back branch $ROLLBACK_BRANCH to $ROLLBACK_SHA" \
        || error "  Rollback failed — manual recovery: git checkout -B $ROLLBACK_BRANCH $ROLLBACK_SHA"
    else
      git checkout "$ROLLBACK_SHA" 2>>"$LOG_FILE" \
        && warn "  Rolled back to detached HEAD at $ROLLBACK_SHA" \
        || error "  Rollback failed — manual recovery: git checkout $ROLLBACK_SHA"
    fi
  fi
}
trap '_rollback' EXIT

# Save each known-local file that exists (modified or not — we own these)
saved_files=()
for f in "${KNOWN_LOCAL_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    mkdir -p "$TMP_DIR/$(dirname "$f")"
    cp "$f" "$TMP_DIR/$f"
    saved_files+=("$f")
    info "  Saved $f"
  fi
done

info "  Checking out $latest_tag..."
git checkout "$latest_tag" 2>>"$LOG_FILE"

info "  Restoring local files..."
for f in "${saved_files[@]}"; do
  mkdir -p "$(dirname "$f")"
  cp "$TMP_DIR/$f" "$f"
  info "  Restored $f"
done

info "  Creating/resetting branch $BRANCH at $latest_tag..."
git checkout -B "$BRANCH" 2>>"$LOG_FILE"
info "  ✓ On branch $BRANCH"

# ── 8. Rebuild image ──────────────────────────────────────────────────────────
step "6/10  Building openclaw:local"
podman build \
  --build-arg NODE_OPTIONS="--max-old-space-size=4096" \
  -t openclaw:local \
  -f Dockerfile \
  . 2>&1 | tee -a "$LOG_FILE"
info "  ✓ Image built"

# ── 9. Restart stack ──────────────────────────────────────────────────────────
step "7/10  Restarting stack"
# Force-remove any dependent CLI/TUI containers first
podman ps -a --filter "name=openclaw.*cli" --format "{{.ID}}" \
  | xargs -r podman rm -f 2>>"$LOG_FILE" || true
podman compose --env-file .env down --remove-orphans --timeout 10 2>&1 | tee -a "$LOG_FILE"
podman compose --env-file .env up -d openclaw-gateway 2>&1 | tee -a "$LOG_FILE"
info "  ✓ Stack restarted"

# ── 10. Post-flight health check ──────────────────────────────────────────────
step "8/10  Waiting for gateway (up to 30s)"
healthy=false
for i in $(seq 1 30); do
  if curl -sf --max-time 2 "http://localhost:18789/healthz" >>"$LOG_FILE" 2>&1; then
    healthy=true
    info "  ✓ Gateway healthy after ${i}s"
    break
  fi
  sleep 1
done
$healthy || die "Gateway did not become healthy within 30s — check: podman compose logs openclaw-gateway"

# ── 11. Commit local customizations ───────────────────────────────────────────
step "9/10  Committing"
# Stage only the files we explicitly own (skip any that don't exist)
files_to_add=()
for f in AGENTS.md CLAUDE.md docker-compose.yml scripts/update-upstream.sh; do
  [[ -f "$f" ]] && files_to_add+=("$f")
done
git add "${files_to_add[@]}"

if git diff --cached --quiet; then
  info "  Nothing to commit (local files identical to $latest_tag)"
else
  git commit -m "chore: update to $latest_tag" 2>&1 | tee -a "$LOG_FILE"
  info "  ✓ Committed"
fi

# ── 12. Push ──────────────────────────────────────────────────────────────────
step "10/10  Pushing to origin/$BRANCH"
git push --force-with-lease origin "$BRANCH" 2>&1 | tee -a "$LOG_FILE"
info "  ✓ Pushed to origin/$BRANCH"

# ── Done ──────────────────────────────────────────────────────────────────────
info ""
info "${GREEN}${BOLD}Update complete: $current_tag → $latest_tag${RESET}"
info "Log: $LOG_FILE"
