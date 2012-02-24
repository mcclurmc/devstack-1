#!/usr/bin/env bash

set +eux

#
# Test the aggregate feature
#

# Settings
# ========

# Use openrc + stackrc + localrc for settings
pushd $(cd $(dirname "$0")/.. && pwd)
source ./openrc
popd

# run test as the admin user
_OLD_USERNAME=$OS_USERNAME
OS_USERNAME=admin


# Create an aggregate
# ===================

AGGREGATE_NAME=test_aggregate_$RANDOM
AGGREGATE_A_ZONE=nova

ensure_aggregate_not_present()
{
    aggregate_name=$1
    
    if [ `nova aggregate-list | grep -c $aggregate_name` == 0 ]
    then
        echo "SUCCESS $aggregate_name not present"
    else
        echo "ERROR found aggregate: $aggregate_name"
        exit -1
    fi
}

ensure_aggregate_not_present $AGGREGATE_NAME

aggregate_id=`nova aggregate-create $AGGREGATE_NAME $AGGREGATE_A_ZONE | head -n 4 | tail -n 1 | cut -d"|" -f2`

# check aggregate created
nova aggregate-list | grep -q $AGGREGATE_NAME


# Ensure creating a duplicate fails
# =================================

set +e
nova aggregate-create $AGGREGATE_NAME $AGGREGATE_A_ZONE
if [ $? == 0 ]
then
    echo "ERROR could create duplicate aggregate"
    exit -1
fi
set -e


# Test aggregate-update (and aggregate-details)
# =============================================
AGGREGATE_NEW_NAME=test_aggregate_$RANDOM

nova aggregate-update $aggregate_id $AGGREGATE_NEW_NAME
nova aggregate-details $aggregate_id | grep $AGGREGATE_NEW_NAME
nova aggregate-details $aggregate_id | grep $AGGREGATE_A_ZONE

nova aggregate-update $aggregate_id $AGGREGATE_NAME $AGGREGATE_A_ZONE
nova aggregate-details $aggregate_id | grep $AGGREGATE_NAME
nova aggregate-details $aggregate_id | grep $AGGREGATE_A_ZONE


# Test aggregate-set-metadata
# ===========================
META_DATA_1_KEY=asdf
META_DATA_2_KEY=foo
META_DATA_3_KEY=bar

#ensure no metadata is set
nova aggregate-details $aggregate_id | grep {}

nova aggregate-set-metadata $aggregate_id ${META_DATA_1_KEY}=123
nova aggregate-details $aggregate_id | grep $META_DATA_1_KEY
nova aggregate-details $aggregate_id | grep 123

nova aggregate-set-metadata $aggregate_id ${META_DATA_2_KEY}=456
nova aggregate-details $aggregate_id | grep $META_DATA_1_KEY
nova aggregate-details $aggregate_id | grep $META_DATA_2_KEY

nova aggregate-set-metadata $aggregate_id $META_DATA_2_KEY ${META_DATA_3_KEY}=789
nova aggregate-details $aggregate_id | grep $META_DATA_1_KEY
nova aggregate-details $aggregate_id | grep $META_DATA_3_KEY

set +e
nova aggregate-details $aggregate_id | grep $META_DATA_2_KEY
if [ $? == 0 ]
then
    echo "ERROR metadata was not cleared"
    exit -1
fi
set -e

nova aggregate-set-metadata $aggregate_id $META_DATA_3_KEY $META_DATA_1_KEY
nova aggregate-details $aggregate_id | grep {}


# Test aggregate-add/remove-host
# ==============================
if [ "$VIRT_DRIVER" == "xenserver" ]
then
    echo "TODO(johngarbutt) add tests for add/remove host from aggregate"
fi


# Test aggregate-delete
# =====================
nova aggregate-delete $aggregate_id
ensure_aggregate_not_present $AGGREGATE_NAME


# Test complete
# =============
OS_USERNAME=$_OLD_USERNAME
echo "AGGREGATE TEST PASSED"
