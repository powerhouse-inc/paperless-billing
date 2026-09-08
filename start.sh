#!/usr/bin/env bash
# One command: bring up Paperless, the reactor, Connect, and the wiring between
# them, then open the browser on the Billing drive.
#
#   ./start.sh
#
# Everything runs in Docker. `docker compose down` stops it (add -v to wipe
# Paperless documents and the reactor's PGlite data).
set -euo pipefail
cd "$(dirname "$0")"

# Compose reads .env automatically; this script did not, so any port set there
# (e.g. SWITCHBOARD_HOST_PORT=4000 to dodge a taken 4001) applied to the
# containers but not to the URLs this script probes and opens -- the readiness
# assertion then queried a dead port and reported a healthy stack as broken.
# Load it here so both see the same values. Done before the .env existence check
# below so the ports are right even in the error paths.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

CONNECT_PORT="${CONNECT_HOST_PORT:-3000}"
SWITCHBOARD_PORT="${SWITCHBOARD_HOST_PORT:-4001}"
PAPERLESS_PORT="${PAPERLESS_HOST_PORT:-8000}"
DRIVE_URL="http://localhost:${CONNECT_PORT}/?driveUrl=http://localhost:${SWITCHBOARD_PORT}/d/billing"
PAPERLESS_UI_URL="http://localhost:${PAPERLESS_PORT}"

OS="$(uname -s)"
IS_WSL=0
if [ "$OS" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- preflight ----------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "Docker is not installed. https://docs.docker.com/engine/install/"
# The docker CLI in a Docker Desktop WSL distro is a symlink into an iso9660
# mount served from the Docker Desktop VM
# (/mnt/wsl/docker-desktop/cli-tools). If Docker Desktop restarts while this
# distro still holds that mount, the symlink survives but every read fails with
# EIO: the binary is present and unusable, and the daemon check below would
# blame the daemon. Name the real cause instead.
if ! docker --version >/dev/null 2>&1; then
  echo "The 'docker' command exists but cannot be executed."
  echo "Reading it: $(docker --version 2>&1 | head -1)"
  echo
  if [ "$IS_WSL" = 1 ]; then
    echo "This is the usual WSL symptom of a stale Docker Desktop integration"
    echo "mount (an 'Input/output error' on /usr/bin/docker). Docker Desktop can"
    echo "be running perfectly on Windows and this still happens."
    echo
    echo "Fix, least disruptive first:"
    echo "  1. Docker Desktop -> Settings -> Resources -> WSL Integration:"
    echo "     toggle this distro OFF, Apply, then ON, Apply."
    echo "  2. If that does not help, from Windows PowerShell:  wsl --shutdown"
    echo "     then open a new terminal."
    echo
    echo "Check the mount with:  ls /mnt/wsl/docker-desktop/cli-tools/usr/bin/"
  else
    echo "Reinstall or repair the Docker CLI."
  fi
  exit 1
fi

docker info >/dev/null 2>&1 || fail "Docker is installed but the daemon is not running."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is missing (the 'docker compose' subcommand)."
command -v curl >/dev/null 2>&1 || fail "curl is required."

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example."
  echo "Fill in PAPERLESS_AI_API_KEY, then run this again."
  exit 1
fi
if ! grep -q '^PAPERLESS_AI_API_KEY=..' .env; then
  fail "PAPERLESS_AI_API_KEY is empty in .env -- fill it in, then run this again."
fi

mkdir -p .local/consume

# --- bring long-running services up ------------------------------------------
# Bootstrap is a one-shot that depends_on Paperless + reactor being healthy.
# `docker compose up -d` (and `up --wait`) honor that by blocking with no
# further output until those healthchecks pass -- which reads as a hang while
# Docker already shows the other containers. Start only the long-running
# services, skip depends_on waits (--no-deps), narrate health ourselves, then
# run bootstrap once they are actually up.
echo "==> Starting Paperless, reactor, and Connect (first run pulls ~2.6 GB, then Paperless migrates)"

if ! docker compose up -d --no-deps broker webserver switchboard connect 2>/tmp/ph-up.err; then
  cat /tmp/ph-up.err >&2
  if grep -q "ports are not available" /tmp/ph-up.err; then
    cat >&2 <<EOF

A host port is already taken. Docker's message is opaque, so in detail:

  switchboard wants $SWITCHBOARD_PORT   connect wants $CONNECT_PORT   paperless wants $PAPERLESS_PORT

On WSL2 the process holding it is often on the WINDOWS side, where 'ss' and
'lsof' inside WSL cannot see it. Check from Windows:

  powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort $SWITCHBOARD_PORT | Select-Object LocalPort,OwningProcess"
  powershell.exe -NoProfile -Command "Get-Process -Id <pid> | Select-Object ProcessName"

Then either stop that process, or pick another port in .env:

  SWITCHBOARD_HOST_PORT=4000
  CONNECT_HOST_PORT=3000
  PAPERLESS_HOST_PORT=8000

Connect's default-drive URL follows SWITCHBOARD_HOST_PORT automatically.
EOF
  fi
  exit 1
fi

svc_label() {
  case "$1" in
    broker) printf 'Redis' ;;
    webserver) printf 'Paperless' ;;
    switchboard) printf 'reactor' ;;
    connect) printf 'Connect' ;;
    *) printf '%s' "$1" ;;
  esac
}

# First line only; never fail the script on SIGPIPE if compose prints extra.
ps_state_health() {
  local out
  out=$(docker compose ps -a --format '{{.State}}|{{.Health}}' "$1" 2>/dev/null || true)
  printf '%s' "${out%%$'\n'*}"
}

# --- wait for health, with visible progress ----------------------------------
echo "==> Waiting for services to become healthy"
wait_deadline=$(( $(date +%s) + 900 ))
spin='|/-\'
spin_i=0
wait_started=$(date +%s)

# Only animate on a real terminal. Piped to a file or CI log, \r does not
# overwrite and a spinner becomes tens of thousands of useless lines, so print a
# plain line every 15s instead.
if [ -t 1 ]; then interactive=1; else interactive=0; fi
last_report=0

while :; do
  pending=""
  missing=""
  for svc in broker webserver switchboard connect; do
    line=$(ps_state_health "$svc")
    if [ -z "$line" ]; then
      missing="$missing $(svc_label "$svc")"
    else
      case "$line" in
        *'|healthy') ;;
        *) pending="$pending $(svc_label "$svc")" ;;
      esac
    fi
  done

  if [ -n "$missing" ]; then
    [ "$interactive" = 1 ] && printf '\r%*s\r' 100 ''
    echo "ERROR: these services have no container:$missing"
    echo "  'docker compose up -d' did not create them. Check:"
    echo "    docker compose ps -a"
    echo "    docker compose logs --tail=50"
    exit 1
  fi

  [ -z "$pending" ] && break

  elapsed=$(( $(date +%s) - wait_started ))

  if [ "$(date +%s)" -ge "$wait_deadline" ]; then
    [ "$interactive" = 1 ] && printf '\r%*s\r' 100 ''
    echo "Still not healthy after 15 minutes. Waiting on:$pending"
    echo "  docker compose ps -a"
    echo "  docker compose logs --tail=50"
    exit 1
  fi

  if [ "$interactive" = 1 ]; then
    spin_i=$(( (spin_i + 1) % 4 ))
    printf '\r  [%s] %4ds  waiting for:%s to become healthy ' \
      "$(printf '%s' "$spin" | cut -c$((spin_i + 1)))" \
      "$elapsed" "$pending"
  elif [ $(( elapsed - last_report )) -ge 15 ]; then
    echo "  ${elapsed}s  waiting for:$pending to become healthy"
    last_report=$elapsed
  fi
  sleep 1
done
[ "$interactive" = 1 ] && printf '\r%*s\r' 100 ''
echo "==> Paperless, reactor, and Connect are healthy ($(( $(date +%s) - wait_started ))s)"

# --- wire Paperless to the reactor -------------------------------------------
# Run only now that deps are healthy. `run --no-deps` starts immediately and
# streams [bootstrap] logs; `up -d` would recreate the Created/exited one-shot
# and wait without output. --rm so a leftover container cannot mask a new run.
# Cap the wait: bootstrap itself gives up after ~7 minutes of probes.
#
# Skip when a sync document already exists: re-running createDocument is not
# fully idempotent (a second "Billing" drive can appear). After `down -v` the
# reactor is empty and this probe is 0, so a fresh start still wires.
wired=$(curl -sS --max-time 15 -X POST -H 'content-type: application/json' \
  -d '{"query":"{ PaperlessSync { documents { totalCount } } }"}' \
  "http://localhost:${SWITCHBOARD_PORT}/graphql" 2>/dev/null || true)
if printf '%s' "$wired" | grep -Eq '"totalCount": *[1-9]'; then
  echo "==> Wiring already present, skipping bootstrap"
else
  echo "==> Wiring Paperless to the reactor"
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground 600 docker compose run --rm --no-deps bootstrap
    bs_code=$?
  else
    docker compose run --rm --no-deps bootstrap
    bs_code=$?
  fi
  set -e
  if [ "$bs_code" -eq 124 ]; then
    echo
    echo "ERROR: bootstrap did not finish within 10 minutes."
    echo "  docker compose logs --tail=50 webserver switchboard"
    exit 1
  fi
  if [ "$bs_code" != "0" ]; then
    echo
    echo "ERROR: the Paperless <-> reactor wiring failed (bootstrap exit $bs_code)."
    exit 1
  fi
  echo "==> Wiring complete"
fi


# --- assert the reactor actually loaded the packages -----------------------
# Packages are loaded from the registry CDN at startup (PH_REGISTRY_PACKAGES),
# not installed into node_modules. Two ways this fails quietly:
#   - the package names are wrong or the registry is unreachable, so the log
#     reads "Loading packages: , /app" and nothing is registered
#   - the image tag does not match the reactor line the packages were built
#     against, so an unknown GraphQL type (e.g. AttachmentRef) fails supergraph
#     composition for EVERY subgraph and switchboard crash-loops
# Either way the drive ends up empty with no obvious cause, so check here.
echo "==> Verifying the reactor loaded the invoice document model"
if ! curl -sS --max-time 15 -X POST -H 'content-type: application/json' \
     -d '{"query":"{ __schema { types { name } } }"}' \
     "http://localhost:${SWITCHBOARD_PORT}/graphql" 2>/dev/null | grep -q '"Invoice"'; then
  echo
  echo "ERROR: the reactor is not serving the Invoice type."
  echo
  echo "  Check, in this order:"
  echo "    1. did the packages load?"
  echo "         docker compose logs switchboard | grep 'Loaded document models'"
  echo "       An empty list ('Loading packages: , /app') means PH_REGISTRY_PACKAGES"
  echo "       or PH_REGISTRY_URL is wrong."
  echo "    2. did supergraph composition fail?"
  echo "         docker compose logs switchboard | grep -i 'Unknown type'"
  echo "       That means PH_IMAGE_TAG does not match the reactor line the"
  echo "       packages were built against (billing targets 6.2.2-dev.53)."
  echo "    3. is it crash-looping?"
  echo "         docker inspect paperless-billing-switchboard-1 --format '{{.RestartCount}}'"
  exit 1
fi

# --- browser ------------------------------------------------------------------
open_url() {
  # Background the non-mac openers: xdg-open/wslview can block until the
  # browser exits, which looks like the script hung after the stack is up.
  if command -v open >/dev/null 2>&1 && [ "$OS" = "Darwin" ]; then open "$1"
  elif [ "$IS_WSL" = 1 ] && command -v wslview >/dev/null 2>&1; then wslview "$1" >/dev/null 2>&1 &
  elif [ "$IS_WSL" = 1 ] && command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process '$1'" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 &
  else echo "    (could not open a browser -- open $1 yourself)"; fi
}
echo "==> Opening Paperless ($PAPERLESS_UI_URL, admin/paperless) and Connect"
open_url "$PAPERLESS_UI_URL"
open_url "$DRIVE_URL"

cat <<EOF

Everything is up.

  Paperless    $PAPERLESS_UI_URL   (admin / paperless)
  Connect      http://localhost:${CONNECT_PORT}
  Reactor API  http://localhost:${SWITCHBOARD_PORT}/graphql

Upload a PDF containing the word "invoice" at $PAPERLESS_UI_URL, or drop it
into .local/consume/ -- it appears in the Billing drive once OCR and extraction
finish. PDFs only: Office formats need tika + gotenberg (commented out in
docker-compose.yml).

  Follow the pipeline   docker compose logs -f switchboard
  Re-run the wiring     docker compose run --rm bootstrap
  Stop                  docker compose down
EOF
