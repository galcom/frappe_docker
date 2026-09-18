#!/bin/bash
# Build the galcom ERPNext image under a versioned tag.
#
#   ./build-galcom.sh                  new dated tag; the app layer is rebuilt and
#                                      everything before it comes from cache
#   ./build-galcom.sh 20260918-1400    build under an explicit tag
#   ./build-galcom.sh --reuse-apps     also reuse the cached app layer. Only correct when
#                                      neither apps.json nor any pinned app branch moved
#   ./build-galcom.sh --full           --no-cache: rebuild every layer (rarely needed)
#   ./build-galcom.sh --app galcom     FAST PATH: refresh one app on top of an existing
#                                      image instead of rebuilding from scratch. Re-clones
#                                      just that app and rebuilds only its assets.
#   ./build-galcom.sh --app galcom --from 20260917-2052
#                                      base it on a specific image (default: the tag this
#                                      project is running, else config/last-built-tag)
#   ./build-galcom.sh --dry-run        print the docker build command and stop
#   ./build-galcom.sh --list           show images available to deploy or roll back to
#   --project NAME  REQUIRED, no default. Selects config/<NAME>.env, which names the
#                   image, and the <NAME>-backend-1 container the prune guard protects.
#                   May also be given as PROJECT=<NAME> in the environment.
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

# Which environment the prune guard consults, and where the image name comes from.
# Override with --project NAME or PROJECT=name. The build itself is environment-agnostic.
# Print the comment header as help.
usage() { awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; }
environments() { ls config/*.env 2>/dev/null | sed 's|config/||; s|\.env$||' | tr '\n' ' '; }

# --help works without a project; everything else needs one.
case " $* " in *" --help "*|*" -h "*) usage; exit 0 ;; esac

# No default on purpose: building or pruning against the wrong environment is not
# something to do by accident. --project, or PROJECT= in the environment.
PROJECT="${PROJECT:-}"
for i in $(seq 1 $#); do
  [ "${!i}" = "--project" ] || continue
  j=$((i+1)); PROJECT="${!j:-}"
done

if [ -z "$PROJECT" ]; then
  usage
  echo "error: --project is required (no default). Available: $(environments)" >&2
  exit 1
fi

CONTEXT=frappe_docker
CONTAINERFILE=images/custom/Containerfile
ENV_FILE=config/$PROJECT.env

if [ ! -f "$ENV_FILE" ]; then
  usage
  echo "error: no such environment '$PROJECT' ($ENV_FILE not found). Available: $(environments)" >&2
  exit 1
fi

IMAGE=$(sed -n 's/^CUSTOM_IMAGE=//p' "$ENV_FILE" 2>/dev/null | head -1)
IMAGE="${IMAGE:-galcom-erp}"

MODE=apps
TAG=""
DRY=0
PRUNE=""
APP=""
FROM_TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --reuse-apps) MODE=reuse-apps ;;
    --full)       MODE=full ;;
    --project)    shift ;;   # consumed in the pre-scan above
    --dry-run)    DRY=1 ;;
    --prune)      PRUNE="${2:-}"; shift ;;
    --app)        APP="${2:-}"; shift ;;
    --from)       FROM_TAG="${2:-}"; shift ;;
    --list)       docker image ls "$IMAGE" --format '  {{.Tag}}  {{.ID}}  {{.CreatedSince}}  {{.Size}}' | sort -r; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
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
  DEPLOYED=$(docker inspect "${PROJECT}-backend-1" --format '{{.Config.Image}}' 2>/dev/null \
               | cut -d: -f2- || true)

  echo "versioned tags : ${#VERSIONS[@]}"
  echo "keeping newest : $PRUNE"
  [ -n "$DEPLOYED" ] && echo "deployed now   : $DEPLOYED (${PROJECT}-backend-1, always kept)"

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

if [ -n "$APP" ]; then
  # Base image: explicit --from, else what this project runs, else the last build.
  if [ -z "$FROM_TAG" ]; then
    FROM_TAG=$(docker inspect "${PROJECT}-backend-1" --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2- || true)
    [ -n "$FROM_TAG" ] || FROM_TAG=$(cat config/last-built-tag 2>/dev/null || true)
  fi
  [ -n "$FROM_TAG" ] || { echo "error: no base image; pass --from <tag>" >&2; exit 1; }
  docker image inspect "$IMAGE:$FROM_TAG" >/dev/null 2>&1 \
    || { echo "error: base image $IMAGE:$FROM_TAG not found" >&2; exit 1; }

  # Pull this app's repo URL and branch out of apps.json. The URL carries a credential,
  # so it goes to the build as a secret file, never as a build arg or on a command line.
  APP_BRANCH=$(python3 - "$APP" <<'PYEOF'
import json, sys
app = sys.argv[1]
for a in json.load(open("frappe_docker/apps.json")):
    if a["url"].rstrip("/").rsplit("/", 1)[-1].replace(".git", "").lower() == app.lower():
        print(a.get("branch", "")); break
PYEOF
)
  [ -n "$APP_BRANCH" ] || { echo "error: app '$APP' not found in frappe_docker/apps.json" >&2; exit 1; }

  SECRET=$(mktemp); chmod 600 "$SECRET"; trap 'rm -f "$SECRET"' EXIT
  python3 - "$APP" > "$SECRET" <<'PYEOF'
import json, sys
app = sys.argv[1]
for a in json.load(open("frappe_docker/apps.json")):
    if a["url"].rstrip("/").rsplit("/", 1)[-1].replace(".git", "").lower() == app.lower():
        sys.stdout.write(a["url"]); break
PYEOF

  echo "image  : $IMAGE:$TAG"
  echo "mode   : app-update ($APP @ $APP_BRANCH)"
  echo "base   : $IMAGE:$FROM_TAG"
  echo "cmd    : (cd $CONTEXT && docker build --build-arg BASE_IMAGE=$IMAGE:$FROM_TAG --build-arg APP=$APP --build-arg APP_BRANCH=$APP_BRANCH --secret id=app_repo,src=<url> --tag $IMAGE:$TAG --file images/custom/Containerfile.app .)"
  [ "$DRY" = 1 ] && exit 0

  cd "$CONTEXT"
  time docker build \
    --build-arg "BASE_IMAGE=$IMAGE:$FROM_TAG" \
    --build-arg "APP=$APP" \
    --build-arg "APP_BRANCH=$APP_BRANCH" \
    --build-arg "CACHE_BUST=$(date -u +%Y%m%dT%H%M%S)" \
    --secret "id=app_repo,src=$SECRET" \
    --tag "$IMAGE:$TAG" \
    --file images/custom/Containerfile.app .
  cd ..
  echo "$TAG" > config/last-built-tag
  echo
  echo "built $IMAGE:$TAG  ($APP refreshed on $IMAGE:$FROM_TAG)"
  echo "deploy with:  ./re-deploy.sh $TAG"
  exit 0
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
