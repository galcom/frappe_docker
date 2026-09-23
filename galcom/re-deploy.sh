#!/bin/bash
# Deploy, or roll back to, a specific image tag.
#
#   ./re-deploy.sh --project NAME    deploy CUSTOM_TAG from config/NAME.env
#   ./re-deploy.sh 20260918-1400     deploy that tag -- this is also how you roll back
#   ./re-deploy.sh --list            available image tags and recent deploys
#   ./re-deploy.sh --migrate         run `bench migrate` after the stack comes up
#   ./re-deploy.sh --backup          run `bench backup` before migrating (recommended)
#   ./re-deploy.sh --migrate-only    run `bench migrate` against the stack as it is.
#                                    Nothing is rendered, pulled, recreated or restarted;
#                                    no tag argument is accepted. Combine with --backup.
#   ./re-deploy.sh --dry-run         render and report only; the running stack is untouched
#
#   --project NAME  REQUIRED, no default. Selects config/<NAME>.env, which supplies the
#                   image, site, compose file list and (via COMPOSE_PROJECT_NAME) the
#                   stack this acts on. May also be given as PROJECT=<NAME>.
#                   Deploying to the wrong environment is not something to do by
#                   accident, so there is deliberately no fallback.
#   ./re-deploy.sh --fast            recreate the backend first and the workers after, so
#                                    only the backend's restart is user-visible. Measured
#                                    on staging: 20.8s of downtime versus 61.6s for the
#                                    default down/up of the whole stack.
#
# --fast compares assets.json between the running and target images. If the assets are
# identical the frontend is left running and the cache clears are skipped (they exist to
# flush stale bundle names). If the assets differ the frontend is cycled too, and the
# caches are cleared. It relies on the nginx `resolver` in the image template: without it
# nginx caches the backend's IP at config load and would proxy to a dead address.
#
# Rolling back after a --migrate is NOT safe by itself: once the schema has changed, an
# older image may not run against it. Use --backup and be prepared to restore.
#
# Rolling back needs no rebuild: every tag built by build-galcom.sh is still on the host.
#
# NOTE: this is not a zero-downtime deploy. It runs `down` then `up -d`, so the whole
# stack is unavailable for roughly a minute.
set -uo pipefail
# This script lives in frappe_docker/galcom/ but operates on the deployment directory
# two levels up, which holds config/ and the frappe_docker checkout. readlink -f so a
# symlink pointing at this script still resolves to the right place.
cd "$(dirname "$(readlink -f "$0")")/../.."

# Which environment. Override with --project NAME or PROJECT=name in the environment.
# Everything else is derived from it, so the same script serves staging and production.
PROJECT="${PROJECT:-}"
for i in $(seq 1 $#); do
  [ "${!i}" = "--project" ] || continue
  j=$((i+1)); PROJECT="${!j:-$PROJECT}"
done

# Print the comment header as help. --help must work before any environment is resolved.
usage() { awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; }
case " $* " in *" --help "*|*" -h "*) usage; exit 0 ;; esac

if [ -z "$PROJECT" ]; then
  usage
  echo "error: --project is required (no default). Available: $(ls config/*.env 2>/dev/null | sed 's|config/||; s|\.env$||' | tr '\n' ' ')" >&2
  exit 1
fi

ENV_FILE=config/$PROJECT.env
if [ ! -f "$ENV_FILE" ]; then
  echo "error: $ENV_FILE not found (wrong --project?). Available: $(ls config/*.env 2>/dev/null | sed 's|config/||; s|\.env$||' | tr '\n' ' ')" >&2
  exit 1
fi

# Read (never source) the env file: it contains backticks that a shell would execute.
envget() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }

IMAGE=$(envget CUSTOM_IMAGE); IMAGE="${IMAGE:-galcom-erp}"

# The compose project name is not always the env-file name: this host keeps production
# settings in production.env but runs the stack as project "erpnext-prod". Deploying under
# the wrong name silently builds a SECOND, empty stack instead of updating the real one,
# so take it from COMPOSE_PROJECT_NAME when the env file sets it.
STACK=$(envget COMPOSE_PROJECT_NAME); STACK="${STACK:-$PROJECT}"
OUT=config/$STACK.yaml
if ! docker ps -a --format '{{.Label "com.docker.compose.project"}}' | grep -qx "$STACK"; then
  echo "note: no existing containers for compose project '$STACK' -- this will create a new stack" >&2
fi

# SITE= wins if present; otherwise take the host out of SITES_RULE=Host(`site`)
SITE=$(envget SITE)
[ -n "$SITE" ] || SITE=$(sed -n 's/^SITES_RULE=.*Host(`\([^`]*\)`).*/\1/p' "$ENV_FILE" | head -1)
[ -n "$SITE" ] || { echo "error: cannot determine the site name; add SITE=<site> to $ENV_FILE" >&2; exit 1; }

# Compose file list, overridable per environment with COMPOSE_FILES= in the env file.
FILES=$(envget COMPOSE_FILES)
FILES="${FILES:-frappe_docker/compose.yaml frappe_docker/overrides/compose.redis.yaml frappe_docker/overrides/compose.multi-bench.yaml config/local_overrides.yaml}"
COMPOSE_ARGS=()
for f in $FILES; do
  [ -f "$f" ] || { echo "error: compose file not found: $f" >&2; exit 1; }
  COMPOSE_ARGS+=(-f "$f")
done

DRY=0; TAG=""; MIGRATE=0; BACKUP=0; FAST=0; MIGRATE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      echo "images on this host:"
      docker image ls "$IMAGE" --format '  {{.Tag}}  ({{.CreatedSince}})' | sort -r
      echo "recent deploys:"
      tail -10 config/deploy-history.log 2>/dev/null | sed 's/^/  /' || true
      [ -s config/deploy-history.log ] || echo "  (none recorded yet)"
      exit 0 ;;
    --project) shift ;;   # consumed in the pre-scan above
    --dry-run) DRY=1 ;;
    --fast)    FAST=1 ;;
    --migrate) MIGRATE=1 ;;
    --migrate-only) MIGRATE_ONLY=1 ;;
    --backup)  BACKUP=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 1 ;;
    *)         TAG="$1" ;;
  esac
  shift
done

if [ -n "$TAG" ]; then
  if ! docker image inspect "$IMAGE:$TAG" >/dev/null 2>&1; then
    echo "error: $IMAGE:$TAG is not on this host. Available:" >&2
    docker image ls "$IMAGE" --format '  {{.Tag}}' >&2
    exit 1
  fi
  export CUSTOM_TAG="$TAG"        # shell env wins over the --env-file value
fi

RUNNING=$(docker inspect ${STACK}-backend-1 --format '{{.Config.Image}}' 2>/dev/null || echo none)

want_tag() { echo "${CUSTOM_TAG:-$(envget CUSTOM_TAG)}"; }
mixed_images() {  # $1 = rendered compose file
  awk -v img="$IMAGE" -v want="$IMAGE:$(want_tag)" '
    /^  [a-zA-Z0-9_-]+:$/ { svc=$1 }
    $1=="image:" && $2 ~ "^" img ":" && $2 != want { print "    " svc " -> " $2 }' "$1" | sort -u
}

render() {
  docker compose --project-name $STACK --env-file $ENV_FILE "${COMPOSE_ARGS[@]}" config
}

# Migrate the running stack in place. Deliberately does not render, recreate or restart
# anything: use it when the image is already deployed and only the database needs to catch
# up. Note that a migration is not undone by rolling the image back -- take --backup.
if [ "$MIGRATE_ONLY" = 1 ]; then
  [ -z "$TAG" ] || { echo "error: --migrate-only does not deploy an image; drop the tag '$TAG'" >&2; exit 1; }
  CID=${STACK}-backend-1
  [ "$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null)" = true ] \
    || { echo "error: $CID is not running; nothing to migrate against" >&2; exit 1; }
  CIMG=$(docker inspect -f '{{.Config.Image}}' "$CID")

  echo "stack   : $STACK"
  echo "site    : $SITE"
  echo "image   : $CIMG  (unchanged -- nothing will be restarted)"

  if [ "$DRY" = 1 ]; then
    [ "$BACKUP" = 1 ] && echo "would backup : bench --site $SITE backup"
    echo "would migrate: bench --site $SITE migrate"
    exit 0
  fi

  if [ "$BACKUP" = 1 ]; then
    echo "== backup =="
    docker exec -w /home/frappe/frappe-bench "$CID" bench --site "$SITE" backup \
      || { echo "ERROR: backup failed; not migrating." >&2; exit 1; }
  else
    echo "note: no backup taken; a migration cannot be undone by redeploying the old image"
  fi

  echo "== migrate =="
  if ! docker exec -w /home/frappe/frappe-bench "$CID" bench --site "$SITE" migrate; then
    echo "ERROR: migrate failed. The site may be in a partially migrated state." >&2
    exit 1
  fi

  HC=$(envget HEALTHCHECK_URL)
  if [ -n "$HC" ]; then
    HC_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $SITE" "$HC" || echo 000)
    case "$HC_CODE" in
      2*|3*) echo "  healthcheck $HC -> $HC_CODE" ;;
      *)     echo "ERROR: healthcheck $HC returned $HC_CODE after migrating." >&2; exit 1 ;;
    esac
  fi

  printf '%s  project=%s  migrate-only  site=%s  image=%s  backup=%s\n' \
    "$(date -u +%FT%TZ)" "$PROJECT" "$SITE" "$CIMG" "$BACKUP" >> config/deploy-history.log
  echo
  echo "migrate complete; no containers were restarted"
  exit 0
fi

if [ "$DRY" = 1 ]; then
  echo "running now : $RUNNING"
  TMP=$(mktemp); render > "$TMP" 2>/dev/null
  echo "stack       : $STACK (compose project)"
  echo "would deploy: $IMAGE:$(want_tag)"
  M=$(mixed_images "$TMP")
  [ -n "$M" ] && { echo "WARNING: these services are pinned to a different image:"; echo "$M"; }
  rm -f "$TMP"
  [ "$BACKUP" = 1 ]  && echo "would backup: yes (bench --site $SITE backup)"
  [ "$MIGRATE" = 1 ] && echo "would migrate: yes (bench --site $SITE migrate)"
  exit 0
fi

# Is gunicorn answering? Any HTTP status counts -- a 404 still means it is serving.
backend_ready() {
  docker compose -p $STACK -f "$OUT" exec -T backend python -c "
import urllib.request, urllib.error, sys
try: urllib.request.urlopen('http://127.0.0.1:8000/api/method/ping', timeout=3)
except urllib.error.HTTPError: pass
except Exception: sys.exit(1)
" >/dev/null 2>&1
}

wait_backend() {
  local n=0
  until backend_ready; do
    n=$((n+1))
    [ "$n" -gt 120 ] && { echo "warning: backend still not answering after ~2min" >&2; return 1; }
    sleep 1
  done
  echo "  backend answering after ${n}s"
}

[ -f "$OUT" ] && cp -p "$OUT" "$OUT.bak-$(date +%Y%m%d-%H%M%S)"
render > "$OUT"

# What we intend to run, not whatever image line happens to come first in the file.
WANT_TAG="${CUSTOM_TAG:-$(envget CUSTOM_TAG)}"
TARGET="$IMAGE:$WANT_TAG"

# A service pinned to a literal tag in an override file silently ignores CUSTOM_TAG, so
# part of the stack keeps running the old build. That is almost never intended: name the
# offenders and stop rather than deploying a mixed stack.
MIXED=$(mixed_images "$OUT")
if [ -n "$MIXED" ]; then
  echo "error: these services are pinned to a different image than $TARGET:" >&2
  echo "$MIXED" >&2
  echo "  They carry a literal 'image:' in an override file (usually config/local_overrides.yaml)." >&2
  echo "  Replace it with: image: \${CUSTOM_IMAGE:-frappe/erpnext}:\${CUSTOM_TAG:-\$ERPNEXT_VERSION}" >&2
  exit 1
fi
echo "running now : $RUNNING"
echo "deploying   : $TARGET   (whole stack down for ~1 minute)"

WORKERS="queue-short queue-long queue-audio scheduler websocket"

if [ "$FAST" = 1 ]; then
  # Do the assets differ between what is running and what we are deploying? assets.json
  # maps every bundle to its content-hashed filename, so one comparison covers all apps.
  asset_hash() {
    docker run --rm --entrypoint sh "$1" -c \
      'md5sum /home/frappe/frappe-bench/assets/assets.json 2>/dev/null | cut -d" " -f1'
  }
  OLD_ASSETS=$(asset_hash "$RUNNING")
  NEW_ASSETS=$(asset_hash "$IMAGE:${TAG:-$(grep -m1 CUSTOM_TAG $ENV_FILE | cut -d= -f2)}")
  if [ -n "$OLD_ASSETS" ] && [ "$OLD_ASSETS" = "$NEW_ASSETS" ]; then
    ASSETS_CHANGED=0; echo "  assets unchanged -> frontend stays up, caches kept warm"
  else
    ASSETS_CHANGED=1; echo "  assets differ -> frontend will be cycled and caches cleared"
  fi

  echo "== backend (the only user-visible restart) =="
  docker compose -p $STACK -f "$OUT" up -d --no-deps backend
  wait_backend
else
  docker compose -p $STACK -f "$OUT" down
  if ! docker compose -p $STACK -f "$OUT" up -d; then
    echo "error: 'docker compose up' failed; the stack is NOT fully running." >&2
    echo "       Check the message above (a port clash or a name collision with another" >&2
    echo "       project on this host is the usual cause), then re-run." >&2
    exit 1
  fi
fi
dc_exec() { docker compose -p $STACK -f "$OUT" exec -T "$@"; }

if [ "$BACKUP" = 1 ]; then
  echo "== backup =="
  if ! dc_exec backend bench --site $SITE backup; then
    echo "ERROR: backup failed; not migrating." >&2
    exit 1
  fi
fi

if [ "$MIGRATE" = 1 ]; then
  echo "== migrate =="
  [ "$BACKUP" = 1 ] || echo "note: no backup was taken; rollback to an older image may not work"
  if ! dc_exec backend bench --site $SITE migrate; then
    echo "ERROR: migrate failed. The stack is up on $TARGET but the site may be unusable." >&2
    echo "       Check the output above before rolling back." >&2
    exit 1
  fi
fi

if [ "$FAST" = 1 ]; then
  echo "== workers and scheduler (site stays up) =="
  docker compose -p $STACK -f "$OUT" up -d --no-deps $WORKERS
  if [ "$ASSETS_CHANGED" = 1 ]; then
    echo "== frontend (assets changed) =="
    docker compose -p $STACK -f "$OUT" up -d --no-deps frontend
  fi
fi

if [ "$FAST" = 0 ] || [ "${ASSETS_CHANGED:-1}" = 1 ]; then
  dc_exec backend bench --site $SITE clear-cache \
    || echo "warning: clear-cache failed (backend may still be starting)"
  dc_exec redis-cache redis-cli FLUSHALL \
    || echo "warning: redis FLUSHALL failed"
else
  echo "  skipped clear-cache and FLUSHALL (assets unchanged)"
fi

# A deploy that leaves the site unreachable must not report success. Set
# HEALTHCHECK_URL=<url> in the env file to have it checked here (the Host header is
# taken from SITE, so localhost works behind traefik).
HC=$(envget HEALTHCHECK_URL)
if [ -n "$HC" ]; then
  HC_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $SITE" "$HC" || echo 000)
  case "$HC_CODE" in
    2*|3*) echo "  healthcheck $HC -> $HC_CODE" ;;
    *)     echo "ERROR: healthcheck $HC returned $HC_CODE -- the deploy completed but the" >&2
           echo "       site is NOT serving. Check traefik routers and nginx before walking away." >&2
           HC_FAILED=1 ;;
  esac
fi

printf '%s  project=%s  deployed=%s  previous=%s  migrate=%s  backup=%s  fast=%s\n' \
  "$(date -u +%FT%TZ)" "$PROJECT" "$TARGET" "$RUNNING" "$MIGRATE" "$BACKUP" "$FAST" >> config/deploy-history.log
echo
echo "deployed $TARGET"
echo "roll back with:  ./re-deploy.sh --project $PROJECT ${RUNNING##*:}"
[ "${HC_FAILED:-0}" = 1 ] && exit 1
exit 0
