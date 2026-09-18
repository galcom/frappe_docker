#!/bin/bash

# Set variables that do not exist
if [[ -z "$BACKEND" ]]; then
  echo "BACKEND defaulting to 0.0.0.0:8000"
  export BACKEND=0.0.0.0:8000
fi
if [[ -z "$SOCKETIO" ]]; then
  echo "SOCKETIO defaulting to 0.0.0.0:9000"
  export SOCKETIO=0.0.0.0:9000
fi
if [[ -z "$UPSTREAM_REAL_IP_ADDRESS" ]]; then
  echo "UPSTREAM_REAL_IP_ADDRESS defaulting to 127.0.0.1"
  export UPSTREAM_REAL_IP_ADDRESS=127.0.0.1
fi
if [[ -z "$UPSTREAM_REAL_IP_HEADER" ]]; then
  echo "UPSTREAM_REAL_IP_HEADER defaulting to X-Forwarded-For"
  export UPSTREAM_REAL_IP_HEADER=X-Forwarded-For
fi
if [[ -z "$UPSTREAM_REAL_IP_RECURSIVE" ]]; then
  echo "UPSTREAM_REAL_IP_RECURSIVE defaulting to off"
  export UPSTREAM_REAL_IP_RECURSIVE=off
fi
if [[ -z "$FRAPPE_SITE_NAME_HEADER" ]]; then
  # shellcheck disable=SC2016
  echo 'FRAPPE_SITE_NAME_HEADER defaulting to $host'
  # shellcheck disable=SC2016
  export FRAPPE_SITE_NAME_HEADER='$host'
fi

if [[ -z "$PROXY_READ_TIMEOUT" ]]; then
  echo "PROXY_READ_TIMEOUT defaulting to 120"
  export PROXY_READ_TIMEOUT=120
fi

if [[ -z "$CLIENT_MAX_BODY_SIZE" ]]; then
  echo "CLIENT_MAX_BODY_SIZE defaulting to 50m"
  export CLIENT_MAX_BODY_SIZE=50m
fi

# shellcheck disable=SC2016
envsubst '${BACKEND}
  ${SOCKETIO}
  ${UPSTREAM_REAL_IP_ADDRESS}
  ${UPSTREAM_REAL_IP_HEADER}
  ${UPSTREAM_REAL_IP_RECURSIVE}
  ${FRAPPE_SITE_NAME_HEADER}
  ${PROXY_READ_TIMEOUT}
	${CLIENT_MAX_BODY_SIZE}' \
  </templates/nginx/frappe.conf.template >/etc/nginx/conf.d/frappe.conf

# dfp_external_storage: render the S3 handoff fragments this image ships, if any.
# Two destinations, because nginx contexts differ: `upstream` is http-level and must go
# to conf.d (auto-included by nginx.conf), while the `location` is pulled into the server
# block by the `include /etc/nginx/dfp/*.conf;` line in the template above.
if [[ -z "$DFP_S3_BACKEND" ]]; then
  echo "DFP_S3_BACKEND defaulting to joshua.galcom.local:9000"
  export DFP_S3_BACKEND=joshua.galcom.local:9000
fi

for t in /templates/nginx/dfp/http/*.conf /templates/nginx/dfp/server/*.conf; do
  [[ -e "$t" ]] || continue
  case "$t" in
    */http/*) dest=/etc/nginx/conf.d ;;
    *)        dest=/etc/nginx/dfp ;;
  esac
  # shellcheck disable=SC2016
  envsubst '${DFP_S3_BACKEND}' <"$t" >"$dest/$(basename "$t")" ||
    echo "warning: could not render $(basename "$t") into $dest (mounted read-only?)"
done

nginx -g 'daemon off;'
