#!/bin/bash

# runs run-nightly.sh (wrapper for nightly.sh) on a given site based on login

SITE_LOGIN=$1 # e.g. login.pads.ci.uchicago.edu

DIR=$2 # e.g., /home/skenny/swift_runs/tests

TEST=$3 # e.g. sites/pads-pbs-coasters.sh

# run test and retrieve results

RUNDIR=run-$( date +"%Y-%m-%d" )

ssh $SITE_LOGIN $DIR/run-nightly.sh $DIR/$TEST
scp -r $SITE_LOGIN:$RUNDIR .
