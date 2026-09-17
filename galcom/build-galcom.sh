#!/bin/bash
# Build the galcom ERPNext image under a versioned tag.
#
#   ./build-galcom.sh                  new dated tag; the app layer is rebuilt and
#                                      everything before it comes from cache
#   ./build-galcom.sh 20260918-1400    build under an explicit tag
#   ./build-galcom.sh --reuse-apps     also reuse the cached app layer. Only correct when
#                                      neither apps.json nor any pinned app branch moved
#   ./build-galcom.sh --full           --no-cache: rebuild every layer (rarely needed)
#   ./build-galcom.sh --dry-run        print the docker build command and stop
#   ./build-galcom.sh --list           show images available to deploy or roll back to
#   ./build-galcom.sh --prune N        keep the newest N versions, delete older ones and
#                                      exit. The currently deployed tag is always kept.
#                                      Combine with --dry-run to preview.
#
# Tags are never reused, so every build remains available:  ./re-deploy.sh <tag>
#
# Why CACHE_BUST exists: apps.json is passed as a BuildKit secret, and secret contents are
# deliberately excluded from the build cache key. Changing apps.json therefore does NOT
# invalidate the layer that installs the apps -- which is why this script used to pass
# --no-cache and rebuild everything. images/custom/Containerfile already declares
# ARG CACHE_BUST and references it in that RUN (`: "${CACHE_BUST}" && ...`) purely so a
# changing value invalidates it. Passing it here rebuilds just the app layer, while the
# apt / python / node / wkhtmltopdf / chromium layers above it stay cached.
set -euo pipefail
# This script lives in frappe_docker/galcom/ but operates on the deployment directory
# two levels up, which holds config/ and the frappe_docker checkout. readlink -f so a
# symlink pointing at this script still resolves to the right place.
cd "$(dirname "$(readlink -f "$0")")/../.."

IMAGE=galcom-erp
CONTEXT=frappe_docker
CONTAINERFILE=images/custom/Containerfile

MODE=apps
TAG=""
DRY=0
PRUNE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --reuse-apps) MODE=reuse-apps ;;
    --full)       MODE=full ;;
    --dry-run)    DRY=1 ;;
    --prune)      PRUNE="${2:-}"; shift ;;
    --list)       docker image ls "$IMAGE" --format '  {{.Tag}}  {{.ID}}  {{.CreatedSince}}  {{.Size}}' | sort -r; exit 0 ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 1 ;;
    *)            TAG="$1" ;;
  esac
  shift
done

if [ -n "$PRUNE" ]; then
  case "$PRUNE" in
    ''|*[!0-9]*) echo "error: --prune needs a positive integer" >&2; exit 1 ;;
  esac
  [ "$PRUNE" -ge 1 ] || { echo "error: --prune must keep at least 1 version" >&2; exit 1; }

  # Only ever consider tags this script produces (YYYYMMDD-HHMM). Hand-made tags such as
  # 1.0.0 or latest are never touched.
  mapfile -t VERSIONS < <(docker image ls "$IMAGE" --format '{{.Tag}}' \
                            | grep -E '^[0-9]{8}-[0-9]{4}$' | sort -r)
  DEPLOYED=$(docker inspect staging-backend-1 --format '{{.Config.Image}}' 2>/dev/null \
               | cut -d: -f2- || true)

  echo "versioned tags : ${#VERSIONS[@]}"
  echo "keeping newest : $PRUNE"
  [ -n "$DEPLOYED" ] && echo "deployed now   : $DEPLOYED (always kept)"

  if [ "${#VERSIONS[@]}" -le "$PRUNE" ]; then
    echo "nothing to remove"
    exit 0
  fi
  for t in "${VERSIONS[@]:$PRUNE}"; do
    if [ "$t" = "$DEPLOYED" ]; then
      echo "  keep   $IMAGE:$t  (currently deployed)"
      continue
    fi
    if [ "$DRY" = 1 ]; then
      echo "  would remove $IMAGE:$t"
    else
      echo "  remove $IMAGE:$t"
      docker rmi "$IMAGE:$t" >/dev/null || echo "    (could not remove; still in use?)"
    fi
  done
  exit 0
fi

TAG="${TAG:-$(date -u +%Y%m%d-%H%M)}"
[ -f "$CONTEXT/apps.json" ] || { echo "error: $CONTEXT/apps.json not found" >&2; exit 1; }

if docker image inspect "$IMAGE:$TAG" >/dev/null 2>&1; then
  echo "error: $IMAGE:$TAG already exists. Tags are kept so you can roll back to them." >&2
  echo "       Choose another tag, or 'docker rmi $IMAGE:$TAG' if it is genuinely junk." >&2
  exit 1
fi

BUILD_ARGS=()
case "$MODE" in
  apps)       BUILD_ARGS+=(--build-arg "CACHE_BUST=$(date -u +%Y%m%dT%H%M%S)") ;;
  reuse-apps) BUILD_ARGS+=(--build-arg "CACHE_BUST=apps-$(sha256sum "$CONTEXT/apps.json" | cut -c1-16)") ;;
  full)       BUILD_ARGS+=(--no-cache) ;;
esac

echo "image : $IMAGE:$TAG"
echo "mode  : $MODE"
echo "cmd   : (cd $CONTEXT && docker build ${BUILD_ARGS[*]} --secret id=apps_json,src=apps.json --tag $IMAGE:$TAG --file $CONTAINERFILE .)"
[ "$DRY" = 1 ] && exit 0

cd "$CONTEXT"
time docker build \
  "${BUILD_ARGS[@]}" \
  --secret id=apps_json,src=apps.json \
  --tag "$IMAGE:$TAG" \
  --file "$CONTAINERFILE" .
cd ..

echo "$TAG" > config/last-built-tag
echo
echo "built $IMAGE:$TAG"
echo "deploy with:  ./re-deploy.sh $TAG"
docker image ls "$IMAGE" --format '  {{.Tag}}  ({{.CreatedSince}})' | head -6
