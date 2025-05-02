#!/bin/bash

# This script will look through directories in its working directory and,
# depending on the filename extension, process them in different ways. Before
# any processing is done, placeholder fields marked with "{-{placeholder}-}" in
# all files will be replaced with variables defined in the file `quadlet_vars'
# in the script's working directory.
# Variables in `quadlet_var' should be defined according to the specification
# "variable=variable_value".
#
# Files will be handled in the following ways.
#
# *.script:
# These are arbitrary scripts that will be executed.
#
# *.container/*.volume/*.network/*.service:
# These files will be copied to $HOME/.config/containers/systemd If the
# corresponding units are currently running `systemctl [--user] daemon-reload'
# will be run and every running unit will be restarted
#
# *.template:
# Files with this extension will take a destination path from their first line.
# The rest of the file will be copied to that specified destination. Missing
# directories are created in the process. File permissions will be copied from
# the template file.
# BE AWARE that environment variables in the destination path will *not* be
# expanded. # line. However, you can use {-{placeholder}-} variables as part of
# the path.
#
# Files are processed in the order above.

shopt -s nullglob
shopt -s extglob

TEMP_DIR=$(mktemp -d)
PROJECT_DIR=$(dirname "$0")
VAR_FILE=$(dirname "$0")/quadlet_vars
declare -A CUSTOM_VARS

if [[ "$EUID" -eq 0  ]]; then
    QUADLET_CONTAINER_DIR="/etc/containers/systemd"
else
    QUADLET_CONTAINER_DIR="$HOME/.config/containers/systemd"
    ROOTFLAG="--user"
fi


mkdir -p "$QUADLET_CONTAINER_DIR"

# Beginning of global functions
read_custom_vars() {
    while IFS="" read -r line || [ -n "$line" ]; do
        key=$(cut -s -d= -f 1 <<< "$line")
        value=$(cut -s -d= -f 2- <<< "$line")
        test -z "$key" && continue
        CUSTOM_VARS["$key"]="$value"
    done < "$VAR_FILE"
}

restart_service_maybe() {
    systemctl $ROOTFLAG is-active --quiet "$1.service" || return
    echo "Restarting $1.service..." >&2
    systemctl $ROOTFLAG restart "$1.service"
}

replace_in_file() {
    local repl

    # allow execution of shell commands in backticks
    if [ "${1:0:1}${1: -1}" = '``' ]; then
        repl="$(exec ${1:1:-1})"
        # trim whitespace
        repl="${repl##*([[:space:]])}"
        repl="${repl%%*([[:space:]])}"
    # next, check if variable was provided by user
    elif [[ -v CUSTOM_VARS["$1"] ]]; then
        repl="${CUSTOM_VARS["$1"]}"
    else
        echo "Warning: $1 not defined in quadlet_vars." >&2
        return
    fi

    # escape backslashes for use with sed
    repl=${repl//\//\\\/}
    sed -i "s/$var/$repl/g" "$2"
}

inject_variables() {
    # find marked variables in the container file
    local template_vars
    mapfile -t template_vars < <(grep -o '{-{[^}]\+}-}' "$1") 
    # if there are none, return
    test "${#template_vars[@]}" -eq 0 && return

    # otherwise insert values from CUSTOM_VARS
    for var in "${template_vars[@]}"; do
        local stripped_var
        stripped_var="${var:3:-3}"
        replace_in_file "$stripped_var" "$1"
    done
}

make_injected_copy() {
    local filebase copy
    filebase=$(basename "$1")
    copy="$TEMP_DIR/$filebase"
    cp "$1" "$copy"
    inject_variables "$copy"
    echo -n "$copy"
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

update_template() {
    local source dest
    source="$1"
    dest="$2"

    diff -q "$dest" <(tail -n+2 "$source") 2>/dev/null >&2 && return
    mkdir -p "$(dirname "$dest")"
    tail -n+2 "$source" > "$dest"
    chown --reference="$source" "$dest"
    echo "$dest updated." >&2
}
# End of global functions


# Initialize CUSTOM_VARS
read_custom_vars

# process scripts
for f in "$PROJECT_DIR/"**/*.script; do
    f_copy=$(make_injected_copy "$f")
    /bin/bash "$f_copy"
    rm "$f_copy"
done

# process containers
updated_containers=()
for f in "$PROJECT_DIR/"**/*.{container,network,volume,service}; do
    f_copy=$(make_injected_copy "$f")
    if ! update_container "$f_copy"; then
        filebase="$(basename "$f")"
        updated_containers+=("${filebase%.*}")
    fi
    rm "$f_copy"
done

if [[ ${#updated_containers[@]} -eq 0 ]]; then
    echo "No updates to container units." >&2
else
    systemctl $ROOTFLAG daemon-reload
    for unit in "${updated_containers[@]}"; do
        restart_service_maybe "$unit"
    done
fi

# process templates
for f in "$PROJECT_DIR/"**/*.template; do
    f_copy=$(make_injected_copy "$f")
    dest=$(head -n1 "$f_copy")
    update_template "$f_copy" "$dest"
    rm "$f_copy"
done

rmdir "$TEMP_DIR"
