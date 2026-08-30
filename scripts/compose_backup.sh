#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf '%s\n' "usage: scripts/compose_backup.sh BACKUP_DIR" >&2
  exit 64
fi

backup_dir=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
compose_file=$project_root/docker-compose.yml

if [ ! -f "$compose_file" ]; then
  printf '%s\n' "anchored Compose file is missing: $compose_file" >&2
  exit 1
fi

compose_seed() {
  docker compose --project-directory "$project_root" --file "$compose_file" "$@"
}

if ! expected_project=$(
  compose_seed config --format json --no-interpolate |
    awk '
      {
        bytes += length($0) + 1
        if (bytes > 1048576) exit 2
      }
      /^  "name": "[^"]*",?[[:space:]]*$/ {
        value = $0
        sub(/^  "name": "/, "", value)
        sub(/",?[[:space:]]*$/, "", value)
        print value
        count += 1
      }
      END { if (count != 1) exit 1 }
    '
); then
  printf '%s\n' "could not resolve one bounded top-level Compose project name" >&2
  exit 1
fi

case "$expected_project" in
  "" | [!a-z0-9]* | *[!a-z0-9_-]*)
    printf '%s\n' "invalid Compose project name" >&2
    exit 1
    ;;
esac

if [ "${#expected_project}" -gt 200 ]; then
  printf '%s\n' "invalid Compose project name" >&2
  exit 1
fi

compose() {
  docker compose --project-directory "$project_root" --file "$compose_file" --project-name "$expected_project" "$@"
}

lock_container=fornacast-recovery-lock-$expected_project

case "$lock_container" in
  "" | [!a-zA-Z0-9]* | *[!a-zA-Z0-9_.-]*)
    printf '%s\n' "invalid recovery lock container name" >&2
    exit 1
    ;;
esac

if [ "${#lock_container}" -gt 255 ]; then
  printf '%s\n' "invalid recovery lock container name" >&2
  exit 1
fi

lock_held=false
writers_stopped=false

on_exit() {
  status=$?
  trap - 0 1 2 15
  set +e
  cleanup_failed=false

  if [ "$writers_stopped" = true ] && [ "$status" -ne 0 ]; then
    compose stop nginx app >/dev/null 2>&1
    emergency_status=$?

    if [ "$emergency_status" -eq 0 ]; then
      printf '%s\n' "backup failed; app and nginx remain stopped; inspect the partial backup before restarting" >&2
    else
      printf '%s\n' "backup cleanup could not confirm app and nginx are stopped" >&2
      printf '%s\n' "verify both writers manually and do not restart either service until recovery is inspected" >&2
      cleanup_failed=true
    fi
  fi

  if [ "$lock_held" = true ]; then
    if ! docker rm "$lock_container" >/dev/null 2>&1; then
      printf '%s\n' "could not release recovery lock container: $lock_container" >&2
      cleanup_failed=true
    fi
  fi

  if [ "$status" -eq 0 ] && [ "$cleanup_failed" = true ]; then
    status=1
  fi

  exit "$status"
}

trap on_exit 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

if ! docker create --name "$lock_container" --network none alpine:3.22 sh -c 'exit 0' \
  >/dev/null 2>&1; then
  printf '%s\n' "recovery lock already exists or could not be acquired: $lock_container" >&2
  printf '%s\n' "inspect the active or stale lock and remove it only when safe: $lock_container" >&2
  exit 75
fi

lock_held=true

resolve_app_identity() {
  app_container=$(compose ps -aq app)
  app_container_count=$(printf '%s\n' "$app_container" | awk 'NF { count += 1 } END { print count + 0 }')

  if [ "$app_container_count" -ne 1 ]; then
    printf '%s\n' "expected exactly one Compose app container" >&2
    return 1
  fi

  app_service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$app_container")
  app_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$app_container")
  data_mounts=$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ printf "%s:%s\n" .Type .Name }}{{ end }}{{ end }}' "$app_container")
  data_mount_count=$(printf '%s\n' "$data_mounts" | awk 'NF { count += 1 } END { print count + 0 }')

  if [ "$app_service" != "app" ] || [ "$app_project" != "$expected_project" ]; then
    printf '%s\n' "refusing an app container without exact Compose labels" >&2
    return 1
  fi

  if [ "$data_mount_count" -ne 1 ]; then
    printf '%s\n' "refusing an app container without one named volume at /data" >&2
    return 1
  fi

  data_mount=$(printf '%s\n' "$data_mounts" | awk 'NF { print; exit }')

  case "$data_mount" in
    volume:?*) data_volume=${data_mount#volume:} ;;
    *)
      printf '%s\n' "refusing an app container without one named volume at /data" >&2
      return 1
      ;;
  esac

  case "$data_volume" in
    "" | [!A-Za-z0-9]* | *[!A-Za-z0-9_.-]*)
      printf '%s\n' "refusing an invalid named volume at /data" >&2
      return 1
      ;;
  esac

  if [ "${#data_volume}" -gt 255 ]; then
    printf '%s\n' "refusing an invalid named volume at /data" >&2
    return 1
  fi
}

resolve_app_identity
mkdir -- "$backup_dir"
backup_dir=$(CDPATH= cd -- "$backup_dir" && pwd)

writers_stopped=true
compose stop nginx app

compose exec -T db sh -eu -c \
  'exec pg_dump --username="$POSTGRES_USER" --format=custom --no-owner --no-privileges "$POSTGRES_DB"' \
  >"$backup_dir/fornacast.dump"

docker run --rm \
  --mount "type=volume,source=$data_volume,target=/data,readonly" \
  alpine:3.22 tar -C /data -czf - . >"$backup_dir/fornacast-data.tgz"

(
  cd "$backup_dir"
  sha256sum fornacast.dump fornacast-data.tgz >SHA256SUMS
)
sync

compose start --wait --wait-timeout 120 app nginx
