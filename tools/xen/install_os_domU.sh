#!/bin/bash

# Exit on errors
set -o errexit

# Abort if localrc is not set
if [ ! -e ../../localrc ]; then
    echo "You must have a localrc with ALL necessary passwords defined before proceeding."
    echo "See the xen README for required passwords."
    exit 1
fi

# This directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Source lower level functions
. $TOP_DIR/../../functions

# Source params - override xenrc params in your localrc to suit your taste
source xenrc

# Echo commands
set -o xtrace

xe_min()
{
  local cmd="$1"
  shift
  xe "$cmd" --minimal "$@"
}

cd $TOP_DIR
if [ -f ./master ]
then
    rm -rf ./master
    rm -rf ./nova
fi
wget https://github.com/openstack/nova/zipball/master --no-check-certificate
unzip -o master -d ./nova
cp -pr ./nova/*/plugins/xenserver/xenapi/etc/xapi.d /etc/
chmod a+x /etc/xapi.d/plugins/*

mkdir -p /boot/guest

GUEST_NAME=${GUEST_NAME:-"DevStackOSDomU"}
SNAME_BASE="base_snapshot"
TNAME_BASE="devstack_base_template_folsom_11.10"
SNAME_PREPARED="prepared_snapshot"
TNAME_PREPARED="devstack_prepared_template_folsom_11.10"
SNAME_READY="before first boot"

# Helper to create networks
# Uses echo trickery to return network uuid
function create_network() {
    br=$1
    dev=$2
    vlan=$3
    netname=$4
    if [ -z $br ]
    then
        pif=$(xe_min pif-list device=$dev VLAN=$vlan)
        if [ -z $pif ]
        then
            net=$(xe network-create name-label=$netname)
        else
            net=$(xe_min network-list  PIF-uuids=$pif)
        fi
        echo $net
        return 0
    fi
    if [ ! $(xe_min network-list  params=bridge | grep -w --only-matching $br) ]
    then
        echo "Specified bridge $br does not exist"
        echo "If you wish to use defaults, please keep the bridge name empty"
        exit 1
    else
        net=$(xe_min network-list  bridge=$br)
        echo $net
    fi
}

function errorcheck() {
    rc=$?
    if [ $rc -ne 0 ]
    then
        exit $rc
    fi
}

# Create host, vm, mgmt, pub networks
VM_NET=$(create_network "$VM_BR" "$VM_DEV" "$VM_VLAN" "vmbr")
errorcheck
MGT_NET=$(create_network "$MGT_BR" "$MGT_DEV" "$MGT_VLAN" "mgtbr")
errorcheck
PUB_NET=$(create_network "$PUB_BR" "$PUB_DEV" "$PUB_VLAN" "pubbr")
errorcheck

# Helper to create vlans
function create_vlan() {
    dev=$1
    vlan=$2
    net=$3
    # VLAN -1 refers to no VLAN (physical network)
    if [ $vlan -eq -1 ]
    then
        return
    fi
    if [ -z $(xe_min vlan-list  tag=$vlan) ]
    then
        pif=$(xe_min pif-list  network-uuid=$net)
        # We created a brand new network this time
        if [ -z $pif ]
        then
            pif=$(xe_min pif-list  device=$dev VLAN=-1)
            xe vlan-create pif-uuid=$pif vlan=$vlan network-uuid=$net
        else
            echo "VLAN does not exist but PIF attached to this network"
            echo "How did we reach here?"
            exit 1
        fi
    fi
}

# Create vlans for vm and management
create_vlan $PUB_DEV $PUB_VLAN $PUB_NET
create_vlan $VM_DEV $VM_VLAN $VM_NET
create_vlan $MGT_DEV $MGT_VLAN $MGT_NET

# dom0 ip
HOST_IP=${HOST_IP:-`ifconfig xenbr0 | grep "inet addr" | cut -d ":" -f2 | sed "s/ .*//"`}

# Set up ip forwarding
if ! grep -q "FORWARD_IPV4=YES" /etc/sysconfig/network; then
    # FIXME: This doesn't work on reboot!
    echo "FORWARD_IPV4=YES" >> /etc/sysconfig/network
fi

# Also, enable ip forwarding in rc.local, since the above trick isn't working
if ! grep -q  "echo 1 >/proc/sys/net/ipv4/ip_forward" /etc/rc.local; then
    echo "echo 1 >/proc/sys/net/ipv4/ip_forward" >> /etc/rc.local
fi

# Enable ip forwarding at runtime as well
echo 1 > /proc/sys/net/ipv4/ip_forward

# Shutdown previous runs
DO_SHUTDOWN=${DO_SHUTDOWN:-1}
if [ "$DO_SHUTDOWN" = "1" ]; then
    # Shutdown all domU's that created previously
    xe_min vm-list  name-label="$GUEST_NAME" | xargs ./scripts/uninstall-os-vpx.sh

    # Destroy any instances that were launched
    for uuid in `xe vm-list | grep -1 instance | grep uuid | sed "s/.*\: //g"`; do
        echo "Shutting down nova instance $uuid"
        xe vm-unpause uuid=$uuid || true
        xe vm-shutdown uuid=$uuid || true
        xe vm-destroy uuid=$uuid
    done

    # Destroy orphaned vdis
    for uuid in `xe vdi-list | grep -1 Glance | grep uuid | sed "s/.*\: //g"`; do
        xe vdi-destroy uuid=$uuid
    done
fi

# Start guest
if [ -z $VM_BR ]; then
    VM_BR=$(xe_min network-list  uuid=$VM_NET params=bridge)
fi
if [ -z $MGT_BR ]; then
    MGT_BR=$(xe_min network-list  uuid=$MGT_NET params=bridge)
fi
if [ -z $PUB_BR ]; then
    PUB_BR=$(xe_min network-list  uuid=$PUB_NET params=bridge)
fi

vm_uuid=""
templateuuid=$(xe template-list name-label="$TNAME_BASE")
if [ -z "$templateuuid" ]
then
    templatename="Ubuntu 11.10 for DevStack (64-bit)"
    template=$(xe_min template-list name-label="$templatename")
    if [ -z "$template" ]
    then
        $TOP_DIR/scripts/xenoneirictemplate.sh "${HOST_IP}/devstackubuntupreseed.cfg"
    fi
    # always update the preseed file, incase we have a newer one
    cp -f $TOP_DIR/devstackubuntupreseed.cfg /opt/xensource/www/
    $TOP_DIR/scripts/install-os-vpx.sh -t "$templatename" -v $VM_BR -m $MGT_BR -p $PUB_BR -l $GUEST_NAME -r $OSDOMU_MEM_MB -k "flat_network_bridge=${VM_BR}"

    # Wait for install to finish
    while true
    do
        state=$(xe_min vm-list name-label="$GUEST_NAME" power-state=halted)
        if [ -n "$state" ]
        then
            break
        else
            echo "Waiting for "$GUEST_NAME" to finish installation..."
            sleep 20
        fi
    done

    vm_uuid=$(xe_min vm-list name-label="$GUEST_NAME")
    xe vm-param-set actions-after-reboot=Restart uuid="$vm_uuid"

    # Make template from VM
    snuuid=$(xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_BASE")
    xe snapshot-clone uuid=$snuuid new-name-label="$TNAME_BASE"
fi

templateuuid=$(xe template-list name-label="$TNAME_PREPARED")
if [ -z "$templateuuid" ]
then
    # if we don't already have a VM at this point, we need to make one
    if [ -z "$vm_uuid" ]
    then
        vm_uuid=$(xe vm-install template="$TNAME_BASE" new-name-label="$GUEST_NAME")
    fi

    # Install XenServer tools, and other such things
    $TOP_DIR/prepare_guest_template.sh "$GUEST_NAME"

    # start the VM to run the prepare steps
    xe vm-start vm="$GUEST_NAME"

    # Wait for prep script to finish and shutdown system
    while true
    do
        state=$(xe_min vm-list name-label="$GUEST_NAME" power-state=halted)
        if [ -n "$state" ]
        then
            break
        else
            echo "Waiting for "$GUEST_NAME" to finish preperation..."
            sleep 20
        fi
    done

    # Make template from VM
    snuuid=$(xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_PREPARED")
    xe snapshot-clone uuid=$snuuid new-name-label="$TNAME_PREPARED"
else
    vm_uuid=$(xe vm-install template="$TNAME_PREPARED" new-name-label="$GUEST_NAME")
fi

$TOP_DIR/build_xva.sh "$GUEST_NAME"

xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_READY"
xe vm-start vm="$GUEST_NAME"
 
function find_ip_by_name() {
  local guest_name="$1"
  local period="$2"
  while true
  do
    devstackip=$(xe vm-list --minimal \
                 name-label=$guest_name \
                 params=networks | sed -ne 's,^.*3/ip: \([0-9.]*\).*$,\1,p')
    if [ -z "$devstackip" ]
    then
      sleep $period
    else
      echo $devstackip
      break
    fi
  done
}

if [ $PUB_IP == "dhcp" ]; then
    PUB_IP=$(find_ip_by_name $GUEST_NAME 10)
fi
export OPENSTACK_GUEST_IP=$PUB_IP

function ssh_no_check() {
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$@"
}

# If we have copied our ssh credentials, use ssh to monitor while the installation runs
WAIT_TILL_LAUNCH=${WAIT_TILL_LAUNCH:-1}
COPYENV=${COPYENV:-1}
if [ "$WAIT_TILL_LAUNCH" = "1" ]  && [ -e ~/.ssh/id_rsa.pub  ] && [ "$COPYENV" = "1" ]; then
    # Done creating the container, let's tail the log
    echo
    echo "============================================================="
    echo "                          -- YAY! --"
    echo "============================================================="
    echo
    echo "We're done launching the vm, about to start tailing the"
    echo "stack.sh log. It will take a second or two to start."
    echo
    echo "Just CTRL-C at any time to stop tailing."

    while ! ssh_no_check -q stack@$PUB_IP "[ -e run.sh.log ]"; do
      sleep 10
    done

    ssh_no_check stack@$PUB_IP 'tail -f run.sh.log' &

    TAIL_PID=$!

    function kill_tail() {
        kill $TAIL_PID
        exit 1
    }

    # Let Ctrl-c kill tail and exit
    trap kill_tail SIGINT

    echo "Waiting stack.sh to finish..."

    # no need to output the commands now
    set +o xtrace

    while ! ssh_no_check -q stack@$PUB_IP "tail run.sh.log | grep -q 'stack.sh completed in'"; do
        sleep 10
    done

    kill $TAIL_PID

    # Echo commands
    set -o xtrace

    if ssh_no_check -q stack@$PUB_IP "grep -q 'stack.sh failed' run.sh.log"; then
        exit 1
    fi
    echo ""
    echo "Finished - Zip-a-dee Doo-dah!"
    echo "You can then visit the OpenStack Dashboard"
    echo "at http://$PUB_IP, and contact other services at the usual ports."
else
    echo "################################################################################"
    echo ""
    echo "All Finished!"
    echo "Now, you can monitor the progress of the stack.sh installation by "
    echo "tailing /opt/stack/run.sh.log from within your domU."
    echo ""
    echo "ssh into your domU now: 'ssh stack@$PUB_IP' using your password"
    echo "and then do: 'tail -f /opt/stack/run.sh.log'"
    echo ""
    echo "When the script completes, you can then visit the OpenStack Dashboard"
    echo "at http://$PUB_IP, and contact other services at the usual ports."
fi
