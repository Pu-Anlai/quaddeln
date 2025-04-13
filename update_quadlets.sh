#!/bin/bash

# This script will replace *.container files in ~/.config/containers/systemd
# with the ones in this repository if they are not identical. If the container
# file is replaced and an associated service is already running that service's
# unit file will be updated and the service will be restarted. The script will
# never start inactive services on its own.

shopt -s nullglob
shopt -s globstar

TEMP_DIR="$(mktemp -d)"
QUADLET_CONTAINER_DIR="$HOME/.config/containers/systemd"
PROJECT_DIR="$(dirname "$0")"
VAR_FILE="$(dirname "$0")/quadlet_vars"
declare -A CUSTOM_VARS

mkdir -p "$QUADLET_CONTAINER_DIR"

declare rootflag
test "$EUID" -eq 0 || rootflag="--user"


# Beginning of global functions
read_custom_vars() {
    while IFS="" read -r line || [ -n "$line" ]; do
        key="$(cut -d= -f 1 <<< "$line")"
        value="$(cut -d= -f 2- <<< "$line")"
        CUSTOM_VARS["$key"]="$value"
    done < "$VAR_FILE"
}

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
    systemctl "$rootflag" is-active --quiet "$1.service" || return
    echo "Restarting $1.service..."
    systemctl "$rootflag" restart "$1.service"
}

inject_variables() {
    # find marked variables in the container file
    local template_vars
    mapfile -t template_vars < <(grep -o '{-{[^}]\+}-}' "$1") 
    # if there are none, return
    test "${#template_vars[@]}" -eq 0 && return

    # otherwise insert values from CUSTOM_VARS
    for var in "${template_vars[@]}"; do
        local stripped_var repl
        stripped_var="${var:3:-3}"
        repl=${CUSTOM_VARS["$stripped_var"]//\//\\\/}
        sed -i "s/$var/$repl/g" "$1"
    done
}
# End of global functions


# Initialize CUSTOM_VARS
read_custom_vars

updated_containers=()
for f in "$PROJECT_DIR/"**/*.container "$PROJECT_DIR/"**/*.network "$PROJECT_DIR/"**/*.volume; do
    # Create a copy of f so we can make edits
    filebase="$(basename "$f")"
    f_copy="$TEMP_DIR/$filebase"
    cp "$f" "$f_copy"

    inject_variables "$f_copy"
    update_container "$f_copy" || updated_containers+=("${filebase%.*}")
    rm "$f_copy"
done

if [[ ${#updated_containers[@]} -eq 0 ]]; then
    echo "No updated containers found."
    exit
else
    systemctl "$rootflag" daemon-reload
    for unit in "${updated_containers[@]}"; do
        systemctl "$rootflag" is-active --quiet "$unit.service" || continue
        echo "Restarting $unit.service..."
        systemctl "$rootflag" restart "$unit.service" 
    done
fi

rmdir "$TEMP_DIR"
