#!/bin/bash
# Deploy, or roll back to, a specific image tag.
#
#   ./re-deploy.sh                   deploy CUSTOM_TAG from config/staging.env
#   ./re-deploy.sh 20260918-1400     deploy that tag -- this is also how you roll back
#   ./re-deploy.sh --list            available image tags and recent deploys
#   ./re-deploy.sh --migrate         run `bench migrate` after the stack comes up
#   ./re-deploy.sh --backup          run `bench backup` before migrating (recommended)
#   ./re-deploy.sh --dry-run         render and report only; the running stack is untouched
#   ./re-deploy.sh --project NAME    act on another environment (default: staging)
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
PROJECT="${PROJECT:-staging}"
for i in $(seq 1 $#); do
  [ "${!i}" = "--project" ] || continue
  j=$((i+1)); PROJECT="${!j:-$PROJECT}"
done

ENV_FILE=config/$PROJECT.env
OUT=config/$PROJECT.yaml
[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found (wrong --project?)" >&2; exit 1; }

# Read (never source) the env file: it contains backticks that a shell would execute.
envget() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }

IMAGE=$(envget CUSTOM_IMAGE); IMAGE="${IMAGE:-galcom-erp}"

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

DRY=0; TAG=""; MIGRATE=0; BACKUP=0
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
    --migrate) MIGRATE=1 ;;
    --backup)  BACKUP=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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

RUNNING=$(docker inspect ${PROJECT}-backend-1 --format '{{.Config.Image}}' 2>/dev/null || echo none)

render() {
  docker compose --project-name $PROJECT --env-file $ENV_FILE "${COMPOSE_ARGS[@]}" config
}

if [ "$DRY" = 1 ]; then
  echo "running now : $RUNNING"
  echo "would deploy: $(render 2>/dev/null | grep -m1 'image:' | tr -d ' ' | cut -d: -f2-)"
  [ "$BACKUP" = 1 ]  && echo "would backup: yes (bench --site $SITE backup)"
  [ "$MIGRATE" = 1 ] && echo "would migrate: yes (bench --site $SITE migrate)"
  exit 0
fi

[ -f "$OUT" ] && cp -p "$OUT" "$OUT.bak-$(date +%Y%m%d-%H%M%S)"
render > "$OUT"
TARGET=$(grep -m1 'image:' "$OUT" | tr -d ' ' | cut -d: -f2-)
echo "running now : $RUNNING"
echo "deploying   : $TARGET   (whole stack down for ~1 minute)"

docker compose -p $PROJECT -f "$OUT" down
docker compose -p $PROJECT -f "$OUT" up -d
dc_exec() { docker compose -p $PROJECT -f "$OUT" exec -T "$@"; }

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

dc_exec backend bench --site $SITE clear-cache \
  || echo "warning: clear-cache failed (backend may still be starting)"
dc_exec redis-cache redis-cli FLUSHALL \
  || echo "warning: redis FLUSHALL failed"

printf '%s  project=%s  deployed=%s  previous=%s  migrate=%s  backup=%s\n' \
  "$(date -u +%FT%TZ)" "$PROJECT" "$TARGET" "$RUNNING" "$MIGRATE" "$BACKUP" >> config/deploy-history.log
echo
echo "deployed $TARGET"
echo "roll back with:  ./re-deploy.sh ${RUNNING##*:}"
