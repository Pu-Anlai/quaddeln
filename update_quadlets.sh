#!/bin/bash

# This script will replace *.container files in ~/.config/containers/systemd
# with the ones in this repository if they are not identical. If the container
# file is replaced and an associated service is already running that service's
# unit file will be updated and the service will be restarted. The script will
# never start inactive services on its own.

shopt -s nullglob

QUADLET_CONTAINER_DIR="$HOME/.config/containers/systemd"
PROJECT_DIR="$(dirname "$0")"

mkdir -p "$QUADLET_CONTAINER_DIR"

rootflag=
test "$EUID" -eq 0 || rootflag="--user"


update_container() {
    local quadlet_path outdated
    quadlet_path="$QUADLET_CONTAINER_DIR/$(basename "$1")"
    diff -q "$1" "$quadlet_path" 2>/dev/null >&2 || outdated=yes
    if [[ -n "$outdated" ]]; then
        cp -v "$1" "$quadlet_path"
        return 1
    fi
}

restart_service_maybe() {
    systemctl $rootflag is-active --quiet "$1.service" || return
    echo "Restarting $1.service..."
    systemctl $rootflag restart "$1.service"
}


updated_containers=()
for dir in "$PROJECT_DIR"/*; do
    test ! -d "$dir" && continue

    for f in "$dir/"*.container "$dir/"*.network "$dir/"*.volume; do
        update_container "$f" && continue
        filebase="$(basename "$f")"
        updated_containers+=("${filebase%.*}")
    done
done

if [[ ${#updated_containers[@]} -eq 0 ]]; then
    echo "No updated containers found."
    exit
else
    systemctl $rootflag daemon-reload
    for unit in "${updated_containers[@]}"; do
        systemctl $rootflag is-active --quiet "$unit.service" || continue
        echo "Restarting $unit.service..."
        systemctl $rootflag restart "$unit.service" 
    done
fi
