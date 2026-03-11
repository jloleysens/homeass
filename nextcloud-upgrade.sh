#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-nextcloudapp}"
CONTAINER_NAME="${CONTAINER_NAME:-nextcloud}"
OCC_USER="${OCC_USER:-www-data}"
TARGET_MAJOR="${TARGET_MAJOR:-33}"
IMAGE_FLAVOR="${IMAGE_FLAVOR:-apache}"

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is not installed or not in PATH." >&2
  exit 1
fi

# Track maintenance mode so we can reliably disable it on failure.
maintenance_enabled=0
cleanup() {
  if [[ "$maintenance_enabled" -eq 1 ]]; then
    echo "Disabling maintenance mode..."
    docker exec -u "$OCC_USER" "$CONTAINER_NAME" php occ maintenance:mode --off || true
  fi
}
trap cleanup EXIT

stored_version="$(
  docker exec "$CONTAINER_NAME" sh -lc \
    "grep -E \"'version'\\s*=>\" /var/www/html/config/config.php | head -n1 | sed -E \"s/.*'([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)'.*/\\1/\""
)"

if [[ -z "$stored_version" ]]; then
  echo "Error: could not read stored Nextcloud version from config.php." >&2
  exit 1
fi

current_major="${stored_version%%.*}"
if ! [[ "$current_major" =~ ^[0-9]+$ ]] || ! [[ "$TARGET_MAJOR" =~ ^[0-9]+$ ]]; then
  echo "Error: current or target major version is not numeric." >&2
  exit 1
fi

if (( current_major > TARGET_MAJOR )); then
  echo "Error: stored major version $current_major is higher than target $TARGET_MAJOR." >&2
  exit 1
fi

echo "Stored Nextcloud version: $stored_version"
echo "Target major version: $TARGET_MAJOR"

echo "Enabling maintenance mode..."
docker exec -u "$OCC_USER" "$CONTAINER_NAME" php occ maintenance:mode --on
maintenance_enabled=1

next_major=$((current_major + 1))
while (( next_major <= TARGET_MAJOR )); do
  image="nextcloud:${next_major}-${IMAGE_FLAVOR}"
  echo "Upgrading to major $next_major with image $image..."
  NEXTCLOUD_IMAGE="$image" docker compose -f "$COMPOSE_FILE" pull "$COMPOSE_SERVICE"
  NEXTCLOUD_IMAGE="$image" docker compose -f "$COMPOSE_FILE" up -d --no-deps "$COMPOSE_SERVICE"
  docker exec -u "$OCC_USER" "$CONTAINER_NAME" php occ upgrade
  next_major=$((next_major + 1))
done

if (( current_major == TARGET_MAJOR )); then
  echo "Already on target major; running occ upgrade for pending minor/db changes..."
  docker exec -u "$OCC_USER" "$CONTAINER_NAME" php occ upgrade
fi

echo "Checking Nextcloud status..."
docker exec -u "$OCC_USER" "$CONTAINER_NAME" php occ status

echo "Showing recent container logs..."
docker logs --tail 100 "$CONTAINER_NAME"

echo "Disabling maintenance mode..."
docker exec -u "$OCC_USER" "$CONTAINER_NAME" php occ maintenance:mode --off
maintenance_enabled=0

echo "Nextcloud upgrade flow completed."
