#!/bin/bash

#
# This runs prepare_guest.sh in the given VM
#
# TODO - share code with build_xva.sh

set -e

declare -a on_exit_hooks

on_exit()
{
    for i in $(seq $((${#on_exit_hooks[*]} - 1)) -1 0)
    do
        eval "${on_exit_hooks[$i]}"
    done
}

add_on_exit()
{
    local n=${#on_exit_hooks[*]}
    on_exit_hooks[$n]="$*"
    if [[ $n -eq 0 ]]
    then
        trap on_exit EXIT
    fi
}

# Abort if localrc is not set
if [ ! -e ../../localrc ]; then
    echo "You must have a localrc with ALL necessary passwords defined before proceeding."
    echo "See the xen README for required passwords."
    exit 1
fi

# This directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Source params - override xenrc params in your localrc to suite your taste
source xenrc

# Echo commands
set -o xtrace

GUEST_NAME="$1"

# Directory where we stage the build
STAGING_DIR=$($TOP_DIR/scripts/manage-vdi open $GUEST_NAME 0 1 | grep -o "/tmp/tmp.[[:alnum:]]*")
add_on_exit "$TOP_DIR/scripts/manage-vdi close $GUEST_NAME 0 1"

# Make sure we have a stage
if [ ! -d $STAGING_DIR/etc ]; then
    echo "Stage is not properly set up!"
    exit 1
fi

# Copy over prepare_guest
cp $TOP_DIR/prepare_guest.sh $STAGING_DIR/opt/stack/

# backup rc.local
cp $STAGING_DIR/etc/rc.local $STAGING_DIR/etc/rc.local.preparebackup

# run prepare_guest.sh on boot
cat <<EOF >$STAGING_DIR/etc/rc.local
GUEST_PASSWORD=$GUEST_PASSWORD STAGING_DIR=/ DO_TGZ=0 bash /opt/stack/prepare_guest.sh > /opt/stack/prepare_guest.log 2>&1
EOF

echo "Done"
