#!/bin/bash


# Set following config options:
cat <<EOF > coaster-service.conf
# Set ipaddr of the headnode
IPADDR=128.135.250.235
WORKER_USERNAME="yadunandb"
WORKER_HOSTS="communicado.ci.uchicago.edu"
WORKER_CONCURRENCY=2
WORKER_MODE=ssh
SSH_TUNNELING="no"
WORKER_LOGGING_LEVEL="DEBUG"
WORKER_LOG_DIR="/home/yadunandb/workers/"
WORKER_LOCATION="/home/yadunandb/workers/"
JOBSPERNODE=$WORKER_CONCURRENCY
EOF


start-coaster-service

if [ "$?" == "0" ]
then
    cp swift.conf wordcount/
fi
