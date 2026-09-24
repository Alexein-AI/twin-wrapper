#!/usr/bin/env bash
# setup.sh - everything `docker compose up` cannot do for itself. Run once.
#
#   ./setup.sh              preflight, .env files, secrets, the host-side agent
#   ./setup.sh --check      report only; nothing is written or installed
#   ./setup.sh --no-agent   skip the Claude Code agent entirely
#   ./setup.sh --pair       open the agent's 2-minute pairing window, nothing else
#   ./setup.sh --help
#
# Then, and every time after that:
#
#   docker compose up -d
#
# This used to be twin-up.sh, which also started four compose stacks in the one
# order that worked. The root docker-compose.yml owns that now. What is left is
# the part no compose file can express:
#
#   1. Two secrets are minted per machine and therefore cannot arrive in a
#      copied .env: the relay secret at ~/.twin-relay/secret, which the backend
#      must hold as TWIN_ENGINE_SECRET, and the agent's own, which pairing
#      exchanges. A copied value is not a missing value - it is a wrong one, and
#      every engine route answers 401 without saying why.
#   2. The relay secret reaches the engine as TWIN_RELAY_SECRET in its .env,
#      copied there from ~/.twin-relay/secret like the backend's copy. It was a
#      read-only mount until the sandbox work, and a mounted file is readable
#      by `execute` where the app's environment is not.
#   3. The Claude Code agent is a host process. It drives tmux and reads
#      ~/.claude on this machine, so no container can hold it and `docker
#      compose build` has nothing to say about it.
#   4. The root .env carries what compose interpolates before a container exists
#      - a volume path, a build argument - and those live in two other files.
#
# Written for stock macOS: bash 3.2 (no mapfile, no associative arrays), BSD
# sed/grep, no jq assumed. Safe to re-run; every step is idempotent.

set -uo pipefail

case "${1:-}" in
  -h | --help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"

CHECK_ONLY=0
WITH_AGENT=1
PAIR_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --no-agent) WITH_AGENT=0 ;;
    --pair) PAIR_ONLY=1 ;;
    *)
      echo "setup: unknown option $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

# Colour only on a terminal, so a piped log stays clean.
if [ -t 1 ]; then
  GRN=$'\033[0;32m' YEL=$'\033[0;33m' RED=$'\033[0;31m'
  BLU=$'\033[1;34m' DIM=$'\033[2m' OFF=$'\033[0m'
else
  GRN='' YEL='' RED='' BLU='' DIM='' OFF=''
fi
say()  { printf '\n%s==>%s %s\n' "$BLU" "$OFF" "$*"; }
ok()   { printf '    %sok%s       %s\n' "$GRN" "$OFF" "$*"; }
info() { printf '    %s.%s        %s\n' "$DIM" "$OFF" "$*"; }
warn() { printf '    %swarn%s     %s\n' "$YEL" "$OFF" "$*"; }
bad()  { printf '    %sfailed%s   %s\n' "$RED" "$OFF" "$*"; }

TODO=()
add_todo() { TODO[${#TODO[@]}]="$1"; }
STATUS=0

# A fatal is something no later step can work around: a missing Docker, a value
# only a person has. Reported with everything else found, then exited on - one
# pass, rather than one failure at a time.
FATAL=0
fatal() { bad "$1"; FATAL=1; STATUS=1; }

print_todo() {
  [ "${#TODO[@]}" -eq 0 ] && return 0
  echo
  printf '%snext:%s\n' "$BLU" "$OFF"
  for t in ${TODO[@]+"${TODO[@]}"}; do printf '  - %s\n' "$t"; done
}

finish_if_fatal() {
  [ "$FATAL" -eq 0 ] && return 0
  echo
  say "stopping - the above has to be true before anything can start"
  print_todo
  exit 1
}

BACKEND="$ROOT/twin-backend"
CONNECTORS="$ROOT/twin-connectors"
ENGINE="$ROOT/twin-engine"
FRONTEND="$ROOT/twin-frontend"
MEMORY="$ROOT/twin-memory"

# --------------------------------------------------------------- env i/o ---
# awk rather than `sed -i`, which is not the same program on macOS and Linux,
# and rather than sed at all, because a secret is base64 and both `/` and `&`
# are meaningful in a sed replacement.

env_get() {
  [ -f "$1" ] || return 1
  grep -E "^$2=" "$1" 2>/dev/null | tail -1 \
    | sed -e "s/^$2=//" -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" | tr -d '\r'
}

# Backups live outside all five repos, in one directory here. Beside the file
# would be simpler and is wrong: twin-connectors/.gitignore ignores `.env` and
# not `.env.*`, so a .env.bak there is a secret git offers to commit.
BACKUP_DIR="$ROOT/.twin-up-backups"
BACKED_UP=''
backup_once() {
  case " $BACKED_UP " in
    *" $1 "*) return 0 ;;
  esac
  dest="$BACKUP_DIR/$(basename "$(dirname "$1")")"
  mkdir -p "$dest" || return 1
  copy="$dest/$(basename "$1").$(date +%Y%m%dT%H%M%S)"
  cp "$1" "$copy" || return 1
  chmod 600 "$copy" 2>/dev/null || true
  BACKED_UP="$BACKED_UP $1"
  info "backed up -> ${copy#$ROOT/}"
}

# Replaces the key's line in place, or appends it. Only ever called for a value
# this script derived - never for one a person chose.
env_set() {
  file=$1 key=$2 value=$3
  [ -f "$file" ] || : >"$file"
  backup_once "$file" || return 1
  tmp="$file.setup.$$"
  KEY="$key" VALUE="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; written = 0 }
    !written && index($0, k "=") == 1 { print k "=" v; written = 1; next }
    { print }
    END { if (!written) print k "=" v }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# Present and non-empty. `.env.example` leaves the optional ones commented
# rather than blank on purpose: z.url() and .min(1) both reject '', where absent
# is what the .optional() is for.
env_has() {
  v="$(env_get "$1" "$2" 2>/dev/null)"
  [ -n "$v" ]
}

# A leading ~ is the only thing in these values that needs expanding, and
# `eval echo` would run whatever else the line happened to contain.
expand_home() {
  case "$1" in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s%s' "$HOME" "${1#\~}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# A url-safe random secret: 32 bytes, base64url, no padding.
new_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_'
  else
    head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_'
  fi
}

# ----------------------------------------------------------------- repos ---
say "repositories"
for d in twin-backend twin-connectors twin-engine twin-frontend twin-memory; do
  if [ -d "$ROOT/$d/.git" ]; then
    branch="$(cd "$ROOT/$d" && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    ok "$d  ($branch)"
    # Not fatal: a fork or a release branch is legitimate. Said out loud because
    # "I cloned the dev branches" and "I am on the dev branches" have come apart.
    [ "$branch" = "dev" ] || warn "  ^ not on dev"
  else
    fatal "$d is missing from $ROOT"
    add_todo "clone $d into $ROOT"
  fi
done
finish_if_fatal

# Pairing is a mode of its own because it cannot be part of a run. The window is
# two minutes and the claim comes from the browser, so it has to be opened while
# somebody is sitting in front of the Connections page.
if [ "$PAIR_ONLY" -eq 1 ]; then
  say "opening the agent's pairing window"
  if ! curl -sf -m 2 http://127.0.0.1:47600/health >/dev/null 2>&1; then
    fatal "the agent is not listening on 127.0.0.1:47600 - run ./setup.sh first"
    finish_if_fatal
  fi
  (cd "$ENGINE" && make agent-pair 2>&1) | sed 's/^/    /'
  status=$?
  echo
  info "now, within two minutes: open http://localhost:4000/connections and press Connect on Claude Code"
  exit "$status"
fi

# ----------------------------------------------------------------- tools ---
say "host tools"
need() {
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; return 0; fi
  fatal "$1 - $2"
  add_todo "install $1: $2"
  return 1
}

need docker "Docker Desktop: https://docker.com/products/docker-desktop"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon"
  else
    fatal "the docker daemon is not running - start Docker Desktop"
  fi
  # The plugin form, not the standalone `docker-compose` v1 binary, which
  # understands neither the profiles nor the `--wait` this tree uses.
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose (plugin)"
  else
    fatal "docker compose plugin absent - the whole tree is written against it"
  fi
fi

# Node and pnpm are not needed to run the stack - every service is a container.
# They are needed for `make check` and `make run` in the three Node repos, so an
# absence is a warning here rather than a failure.
if command -v node >/dev/null 2>&1; then
  nv="$(node -v)"
  case "$nv" in
    v2[2-9]* | v[3-9][0-9]*) ok "node $nv (>= 22)" ;;
    *) warn "node $nv - >= 22 is what the repos build against; the containers carry their own" ;;
  esac
else
  warn 'node absent - the containers carry their own, but make check needs it on the host'
fi
if command -v pnpm >/dev/null 2>&1 || command -v corepack >/dev/null 2>&1; then
  ok "pnpm/corepack"
else
  warn "pnpm absent - corepack enable, or brew install pnpm"
fi

# The agent's half. Soft, because --no-agent is a supported way to run and the
# containers all come up without any of it.
if [ "$WITH_AGENT" -eq 1 ]; then
  # Hardcoded in claude-agent/src/drive/tmux.ts with no environment override, so
  # this is a path check and not a `command -v` one.
  if [ -x /opt/homebrew/bin/tmux ]; then
    ok "tmux at /opt/homebrew/bin/tmux"
  else
    warn "tmux is not at /opt/homebrew/bin/tmux - the path is hardcoded with no override"
    add_todo "brew install tmux (the agent looks only at /opt/homebrew/bin/tmux)"
  fi
  if [ -x /opt/homebrew/bin/claude ] || command -v claude >/dev/null 2>&1; then
    ok "claude CLI"
    [ -d "$HOME/.claude" ] || warn "~/.claude is empty - log the claude CLI in first"
  else
    warn "claude CLI absent - npm i -g @anthropic-ai/claude-code, then log in"
    add_todo "install and log in the claude CLI"
  fi
fi
finish_if_fatal

# ------------------------------------------------------------- env files ---
# The names are not interchangeable. The frontend's is .env.local, which is what
# `next dev` reads and what compose loads; a .env there is read by nobody.
say "env files"
ensure_env() {
  file=$1 example=$2 label=$3
  if [ -f "$file" ]; then ok "$label"; return 0; fi
  if [ "$CHECK_ONLY" -eq 1 ]; then
    bad "$label is missing"
    FATAL=1 STATUS=1
    return 1
  fi
  if [ -f "$example" ]; then
    cp "$example" "$file" && chmod 600 "$file"
    warn "$label was missing - copied from $(basename "$example"); its blanks are listed below"
    return 0
  fi
  fatal "$label is missing and there is no $(basename "$example") to copy"
  return 1
}
ensure_env "$BACKEND/.env" "$BACKEND/.env.example" "twin-backend/.env"
ensure_env "$CONNECTORS/.env" "$CONNECTORS/.env.example" "twin-connectors/.env"
ensure_env "$ENGINE/.env" "$ENGINE/.env.example" "twin-engine/.env"
ensure_env "$FRONTEND/.env.local" "$FRONTEND/.env.example" "twin-frontend/.env.local"
ensure_env "$MEMORY/.env" "$MEMORY/.env.example" "twin-memory/.env"
finish_if_fatal

# Values only a person can supply. Every one of these fails quietly rather than
# loudly if left blank - an unconfigured connector is still listed and still
# offers its actions, Clerk's absence just means nothing can sign in - so they
# are checked here instead of being discovered later.
say "values this script cannot mint"
require_value() {
  if env_has "$1" "$2"; then
    ok "$3 $2"
  else
    fatal "$3 $2 is empty - $4"
    add_todo "set $2 in $3"
  fi
}
require_value "$BACKEND/.env" CLERK_SECRET_KEY "twin-backend/.env" \
  "Clerk holds every person and organization (ADR 37)"
require_value "$BACKEND/.env" CLERK_JWT_KEY "twin-backend/.env" \
  "without both, only a twk_ API key can authenticate and sign-in has nothing to talk to"
require_value "$ENGINE/.env" OPENROUTER_KEY "twin-engine/.env" \
  "the runtime has no model without it"
require_value "$FRONTEND/.env.local" NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY "twin-frontend/.env.local" \
  "next build inlines it into the client bundle, so it must be right before the build"
require_value "$FRONTEND/.env.local" CLERK_SECRET_KEY "twin-frontend/.env.local" \
  "the server half needs it too"
require_value "$FRONTEND/.env.local" TWIN_PUBLIC_URL "twin-frontend/.env.local" \
  "the frontend's own public origin, which it sends as returnTo when you press Connect"

# One origin in two repos. The frontend sends `<TWIN_PUBLIC_URL>/connections` as
# `returnTo`; `safeReturnTo` in the backend refuses any origin that is not
# FRONTEND_URL's. They disagree silently until somebody presses Connect and gets
# "returnTo is not on http://localhost:4000: http://localhost:8080".
public_origin="$(env_get "$FRONTEND/.env.local" TWIN_PUBLIC_URL 2>/dev/null)"
frontend_url="$(env_get "$BACKEND/.env" FRONTEND_URL 2>/dev/null)"
origin_of() { printf '%s' "$1" | sed -E 's#^([a-z]+://[^/]+).*#\1#'; }
if [ -n "$public_origin" ] && [ -n "$frontend_url" ]; then
  if [ "$(origin_of "$public_origin")" = "$(origin_of "$frontend_url")" ]; then
    ok "TWIN_PUBLIC_URL and the backend's FRONTEND_URL share an origin"
  else
    fatal "TWIN_PUBLIC_URL is $(origin_of "$public_origin") but twin-backend's FRONTEND_URL is $(origin_of "$frontend_url")"
    add_todo "make TWIN_PUBLIC_URL (twin-frontend/.env.local) and FRONTEND_URL (twin-backend/.env) the same origin, or Connect is refused"
  fi
fi
finish_if_fatal

# ------------------------------------------------------------- twin root ---
# One string in two namespaces. The engine mounts TWIN_ROOT into its container
# at the same absolute path it has on the host, because a cwd the twin hands to
# sessions.spawn is a host path to the agent and a container path to the engine.
say "TWIN_ROOT"
twin_root="$(expand_home "$(env_get "$ENGINE/.env" TWIN_ROOT 2>/dev/null)")"
if [ -z "$twin_root" ]; then
  fatal "TWIN_ROOT is empty in twin-engine/.env - compose declares it \${TWIN_ROOT:?} and will not start"
  add_todo "set TWIN_ROOT in twin-engine/.env to an absolute path on this machine"
else
  case "$twin_root" in
    /*) ;;
    *) fatal "TWIN_ROOT is '$twin_root', which is not absolute - it is mounted at the same path inside the container" ;;
  esac
  # Somebody else's home directory, which is the shape a copied .env takes: the
  # path is absolute and plausible and belongs to the machine it came from.
  # Worth refusing rather than creating, because `mkdir -p` succeeds and the
  # twin then works in a tree nothing else on this machine knows about.
  case "$twin_root" in
    "$HOME" | "$HOME"/*) ;;
    /Users/* | /home/*)
      fatal "TWIN_ROOT is $twin_root, which is not under this machine's home ($HOME)"
      add_todo "set TWIN_ROOT in twin-engine/.env to a path on this machine"
      ;;
  esac
  # The backend holds the same path - it builds the workspace jail from it - and
  # a mismatch is two services disagreeing about where a tenant's files are.
  be_root="$(expand_home "$(env_get "$BACKEND/.env" TWIN_ROOT 2>/dev/null)")"
  if [ -n "$be_root" ] && [ "$be_root" != "$twin_root" ]; then
    warn "twin-backend/.env has TWIN_ROOT=$be_root, a different path from the engine's"
    add_todo "make TWIN_ROOT the same string in twin-backend/.env and twin-engine/.env"
    STATUS=1
  fi
  if [ "$FATAL" -eq 1 ]; then
    :
  elif [ -d "$twin_root" ]; then
    ok "$twin_root exists"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "$twin_root does not exist - would create it"
  else
    mkdir -p "$twin_root" && ok "created $twin_root"
  fi
fi
finish_if_fatal

# --------------------------------------------------------------- secrets ---
# The two that are per-machine, done before anything starts so that no service
# boots holding a value it would have to be restarted to unlearn.
say "per-machine secrets"

# 1. CREDENTIAL_ENCRYPTION_KEY and CONNECTORS_SECRET, via the backend's own
#    target. It appends rather than regenerates, deliberately: the encryption
#    key in that file decrypts every stored credential.
[ "$CHECK_ONLY" -eq 0 ] && (cd "$BACKEND" && make secrets 2>&1 | sed 's/^/    /')

backend_secret="$(env_get "$BACKEND/.env" CONNECTORS_SECRET 2>/dev/null)"
if [ -z "$backend_secret" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "CONNECTORS_SECRET is unset - 'make secrets' in twin-backend would mint it"
  else
    fatal "CONNECTORS_SECRET is still empty after 'make secrets' in twin-backend"
  fi
else
  ok "CONNECTORS_SECRET minted in twin-backend"
  # 2. The same string in twin-connectors, or every call between them is a 401
  #    compared in constant time and explained nowhere.
  if [ "$(env_get "$CONNECTORS/.env" CONNECTORS_SECRET 2>/dev/null)" = "$backend_secret" ]; then
    ok "CONNECTORS_SECRET matches in twin-connectors"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "CONNECTORS_SECRET in twin-connectors does not match the backend's - would copy it"
    STATUS=1
  else
    env_set "$CONNECTORS/.env" CONNECTORS_SECRET "$backend_secret" \
      && ok "copied CONNECTORS_SECRET into twin-connectors/.env" \
      || fatal "could not write twin-connectors/.env"
  fi
fi

# 3. The relay secret, minted here rather than by the engine, which would mint
#    one of its own that nothing else holds.
relay_dir="$(expand_home "$(env_get "$ENGINE/.env" TWIN_RELAY_DIR 2>/dev/null || echo "$HOME/.twin-relay")")"
[ -n "$relay_dir" ] || relay_dir="$HOME/.twin-relay"
relay_file="$relay_dir/secret"
if [ -f "$relay_file" ]; then
  ok "relay secret present at $relay_file"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  warn "no relay secret at $relay_file - would mint one"
else
  mkdir -p "$relay_dir"
  # Created empty at 0600 first, so the window in which it exists and is
  # world-readable is the two syscalls between - which is what
  # twin_relay/secret.py does, and for the same reason. The umask is scoped to
  # the subshell rather than set here, where it would follow every later file.
  (umask 077 && : >"$relay_file")
  new_secret >"$relay_file"
  chmod 600 "$relay_file"
  ok "minted the relay secret at $relay_file"
fi

# 4. And the backend's copy. This is the one a copied .env gets wrong rather
#    than leaves blank: with a stale secret the twin's conversations still read
#    while every command route answers 401.
if [ -f "$relay_file" ]; then
  relay_secret="$(tr -d '\r\n' <"$relay_file")"
  if [ "$(env_get "$BACKEND/.env" TWIN_ENGINE_SECRET 2>/dev/null)" = "$relay_secret" ]; then
    ok "TWIN_ENGINE_SECRET matches the relay secret"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "TWIN_ENGINE_SECRET does not match $relay_file - would copy it across"
    STATUS=1
  else
    env_set "$BACKEND/.env" TWIN_ENGINE_SECRET "$relay_secret" \
      && ok "copied the relay secret into twin-backend/.env as TWIN_ENGINE_SECRET" \
      || fatal "could not write twin-backend/.env"
  fi
fi

# 5. And the engine's, which it reads from its environment. A stale one fails
#    the same way: every command route answers 401.
if [ -f "$relay_file" ]; then
  if [ "$(env_get "$ENGINE/.env" TWIN_RELAY_SECRET 2>/dev/null)" = "$relay_secret" ]; then
    ok "TWIN_RELAY_SECRET matches the relay secret"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "TWIN_RELAY_SECRET in twin-engine/.env does not match $relay_file - would copy it across"
    STATUS=1
  else
    env_set "$ENGINE/.env" TWIN_RELAY_SECRET "$relay_secret" \
      && ok "copied the relay secret into twin-engine/.env as TWIN_RELAY_SECRET" \
      || fatal "could not write twin-engine/.env"
  fi
fi
finish_if_fatal

# -------------------------------------------------------------- root env ---
# Only what compose interpolates *before* a container exists: a volume path and
# a build argument. Everything else each service needs is in that repository's
# own .env, which docker-compose.yml loads with `env_file`.
say "root .env"
clerk_key="$(env_get "$FRONTEND/.env.local" NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY 2>/dev/null)"
if [ "$CHECK_ONLY" -eq 1 ]; then
  [ -f "$ROOT/.env" ] && ok ".env exists" || warn "no root .env - would write TWIN_ROOT and the Clerk key"
else
  [ -f "$ROOT/.env" ] || { cp "$ROOT/.env.example" "$ROOT/.env" && chmod 600 "$ROOT/.env"; }
  env_set "$ROOT/.env" TWIN_ROOT "$twin_root" && ok "TWIN_ROOT=$twin_root"
  # Copied rather than referenced: compose reads one .env, and `next build`
  # needs this as a build argument, which `env_file` cannot supply.
  env_set "$ROOT/.env" NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY "$clerk_key" \
    && ok "NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY copied from twin-frontend/.env.local"
  # The tunnel token, for the same reason: compose interpolates `--token` from
  # this file before any container exists, so a token sitting only in
  # twin-backend/.env resolves to `--token ""` and cloudflared exits on it. That
  # is where it lived when the backend's Makefile started the tunnel by hand.
  tunnel_token="$(env_get "$BACKEND/.env" CLOUDFLARE_TUNNEL_TOKEN 2>/dev/null)"
  if [ -n "$tunnel_token" ]; then
    env_set "$ROOT/.env" CLOUDFLARE_TUNNEL_TOKEN "$tunnel_token" \
      && ok "CLOUDFLARE_TUNNEL_TOKEN copied from twin-backend/.env"
  else
    info "no CLOUDFLARE_TUNNEL_TOKEN - the tunnel profiles stay off, which is the default"
  fi
fi

# The broker's two tokens: the engine presents one to it, it presents the other
# back. The root compose names both in `engine` and in `sandbox-broker`, so this
# file is their one copy. Minted once, then kept.
for key in TWIN_SANDBOX_BROKER_TOKEN TWIN_SANDBOX_AUDIT_TOKEN; do
  if env_has "$ROOT/.env" "$key"; then
    ok "$key present"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "no $key in the root .env - would mint it"
  else
    env_set "$ROOT/.env" "$key" "$(new_secret)" && ok "minted $key"
  fi
done

# ------------------------------------------------------------ sandbox images ---
# What tenant containers and their egress proxy are made from. The broker
# refuses to start without them, and compose builds no image no service runs.
# Built only when missing: after a change to infra/sandbox or twin_egress, run
# `make sandbox-image egress-image` in twin-engine.
say "sandbox images"
for pair in "twin-sandbox:dev sandbox-image" "twin-egress:dev egress-image"; do
  image=${pair% *} target=${pair#* }
  if docker image inspect "$image" >/dev/null 2>&1; then
    ok "$image present"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    warn "no $image - would build it (make $target in twin-engine)"
  elif (cd "$ENGINE" && make "$target" >/dev/null 2>&1); then
    ok "built $image"
  else
    fatal "could not build $image - run make $target in twin-engine"
  fi
done
finish_if_fatal

# The host-side spellings, which compose overrides for every container but
# `make run` and `make api` still read. Warned rather than rewritten: which
# server a person wants on their own machine is their call.
say "host-side database urls"
check_host_url() {
  file=$1 key=$2 want=$3 label=$4
  have="$(env_get "$file" "$key" 2>/dev/null)"
  if [ "$have" = "$want" ]; then
    ok "$label $key"
  elif [ -z "$have" ]; then
    info "$label $key is unset - only a host-side run would notice"
  else
    warn "$label $key is $have"
    warn "  the shared server is $want (containers are unaffected - compose pins theirs)"
  fi
}
check_host_url "$BACKEND/.env" DATABASE_URL "postgres://twin:twin@localhost:5500/twin_backend" "twin-backend/.env"
check_host_url "$BACKEND/.env" REDIS_URL "redis://localhost:6500" "twin-backend/.env"
check_host_url "$ENGINE/.env" DATABASE_URL "postgresql+psycopg://twin:twin@localhost:5500/twin_engine" "twin-engine/.env"

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "check only - nothing was written or installed"
  print_todo
  exit "$STATUS"
fi

# ----------------------------------------------------------------- agent ---
if [ "$WITH_AGENT" -eq 1 ]; then
  say "claude-code agent (a host process - no container has anything to do with it)"
  (cd "$ENGINE/claude-agent" && pnpm install --prefer-offline --silent 2>&1 | sed 's/^/    /')
  # install.sh, not `make agent-up`: the launch agent is what survives a reboot,
  # and `--restart` on a machine that never installed it prints a line and exits
  # 0 - exactly the silent no-op this script exists to prevent.
  (cd "$ENGINE/claude-agent" && ./service/install.sh 2>&1 | sed 's/^/    /')
  if curl -sf -m 5 http://127.0.0.1:47600/health >/dev/null 2>&1; then
    ok "agent answers on 127.0.0.1:47600"
  else
    warn "the agent is not listening - claude-code sessions will never arrive, and the"
    warn "  backend spends 30s x 3 attempts a cycle discovering that"
    add_todo "check twin-engine/claude-agent/.run/agent.log"
    STATUS=1
  fi
fi

# ------------------------------------------------------------------ done ---
say "set up"
cat <<'EOF'
    docker compose up -d        <- the whole stack, from here

    frontend    http://localhost:4000      open this one
    backend     http://localhost:8080
    engine      http://127.0.0.1:8000      unauthenticated dev harness, loopback only
    memory      http://127.0.0.1:8200      retrieval only, loopback only
    connectors  connectors:8090            no host port, by design
    postgres    localhost:5500             twin_backend / twin_engine / twin_memory
    redis       localhost:6500
EOF
echo
printf '%sthe two steps a script cannot do for you:%s\n' "$BLU" "$OFF"
cat <<'EOF'
  1. Sign in at http://localhost:4000. Identity is Clerk's (ADR 37), so this is
     a browser sign-in and there is no terminal equivalent.
  2. Pair Claude Code. Open http://localhost:4000/connections, then run
     ./setup.sh --pair and press Connect within two minutes. The agent mints its
     own token during that claim; nothing is pasted.
EOF
echo
info "logs:     docker compose logs -f <service>"
info "teardown: docker compose down          (add -v to drop the databases too)"
info "a connector other than claude-code also needs its OAuth pair in twin-backend/.env"
print_todo
exit "$STATUS"
