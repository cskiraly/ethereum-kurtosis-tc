#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/docker-common.sh"
. "$SCRIPT_DIR/tc-common.sh"

# get id of all EL containers
get_el_containers() {
    docker ps -q --filter "name=^el-"
}

# get id of all CL containers
get_cl_containers() {
    docker ps -q --filter "name=^cl-"
}

echo "EL containers:"
get_el_containers

echo "CL containers:"
get_cl_containers

NETM_OPTIONS=
DOWNLINK_TBF_OPTIONS=
UPLINK_TBF_OPTIONS=
OPTIONS_LOG=
query="$1"
while read -r param; do
    FIELD="${param%%=*}"
    VALUE="${param#*=}"

    case "$FIELD" in
        delay|loss|corrupt|duplicate|reorder)
            NETM_OPTIONS+="$FIELD $VALUE "
            ;;
        downlink)
            DOWNLINK_TBF_OPTIONS+="rate $VALUE "
            ;;
        uplink)
            UPLINK_TBF_OPTIONS+="rate $VALUE "
            ;;
        *)
            echo "Error: Invalid field $FIELD"
            exit 1
            ;;
    esac
    OPTIONS_LOG+="$FIELD=$VALUE, "
done < <(echo -e "$query" | tr '&' $'\n')

echo "NETM_OPTIONS: $NETM_OPTIONS"
echo "DOWNLINK_TBF_OPTIONS: $DOWNLINK_TBF_OPTIONS"
echo "UPLINK_TBF_OPTIONS: $UPLINK_TBF_OPTIONS"

if [ -z "$NETM_OPTIONS" ] && [ -z "$DOWNLINK_TBF_OPTIONS" ] && [ -z "$UPLINK_TBF_OPTIONS" ]; then
    echo "Notice: Nothing to do"
    exit 0
fi
OPTIONS_LOG=$(echo "$OPTIONS_LOG" | sed 's/[, ]*$//')
echo "Options: $OPTIONS_LOG"
# CONTAINER_NETWORKS=$(docker_container_get_networks "$CONTAINER_ID")
while read -r CONTAINER_ID; do

    echo "Processing container: $CONTAINER_ID"
    CONTAINER_ID=$(docker_container_get_short_id "$CONTAINER_ID")
    if ! docker_container_is_running "$CONTAINER_ID"; then
        echo "Error: Container $CONTAINER_ID is not running"
        exit 1
    fi

    # Set up ingress (downlink) shaping

    CONTAINER_NETWORKS=$(docker_container_get_networks "$CONTAINER_ID")
    if [ -z "$CONTAINER_NETWORKS" ]; then
        echo "Error: No networks found for container $CONTAINER_ID"
        exit 1
    fi

    echo "Container $CONTAINER_ID is connected to networks: $CONTAINER_NETWORKS"

    while read NETWORK_ID; do
        NETWORK_INTERFACE_NAMES=$(docker_container_interfaces_in_network "$CONTAINER_ID" "$NETWORK_ID")
        if [ -z "$NETWORK_INTERFACE_NAMES" ]; then
            continue
        fi
        while IFS= read -r NETWORK_INTERFACE_NAME; do
            tc_init
            qdisc_del "$NETWORK_INTERFACE_NAME"

            qdisc_filter_by_port "$NETWORK_INTERFACE_NAME"
            if [ ! -z "$NETM_OPTIONS" ]; then
                qdisc_netm "$NETWORK_INTERFACE_NAME" $NETM_OPTIONS
            fi
            if [ ! -z "$DOWNLINK_TBF_OPTIONS" ]; then
                qdisc_tbf "$NETWORK_INTERFACE_NAME" $DOWNLINK_TBF_OPTIONS
            fi
            echo "Set ${OPTIONS_LOG} on $NETWORK_INTERFACE_NAME"
            echo "Controlling traffic of the container $(docker_container_get_name "$CONTAINER_ID") on $NETWORK_INTERFACE_NAME"
        done < <(echo -e "$NETWORK_INTERFACE_NAMES")
    done < <(echo -e "$CONTAINER_NETWORKS")

    # Set up egress (uplink) shaping
    docker_container_init_internal "$CONTAINER_ID"

    IF="eth0"
    # delete existing qdisc
    docker_container_internal_netns_exec "$CONTAINER_ID" \
        tc qdisc del dev "$IF" root

    if [ ! -z "$UPLINK_TBF_OPTIONS" ]; then
        # add uplink limits
        # Set up classes to exclude control and measurement traffic:
        # fef2243b0595   el-1-geth-lighthouse                     engine-rpc: 8551/tcp -> 127.0.0.1:32001        RUNNING
        #                                                         metrics: 9001/tcp -> http://127.0.0.1:32002    
        #                                                         rpc: 8545/tcp -> 127.0.0.1:32003               
        #                                                         tcp-discovery: 32000/tcp -> 127.0.0.1:32000    
        #                                                         udp-discovery: 32000/udp -> 127.0.0.1:32000    
        #                                                         ws: 8546/tcp -> 127.0.0.1:32004             
        # add uplink limits
        docker_container_internal_netns_exec "$CONTAINER_ID" \
            tc qdisc add dev "$IF" root handle 1: prio
        # exclude engine-rpc, rpc, ws, metrics by sending to class 1:1
        # TODO: get ports from labels
        exclude_ports="8551 8545 8546 9001"
        for port in $exclude_ports; do
            docker_container_internal_netns_exec "$CONTAINER_ID" \
                tc filter add dev "$IF" protocol ip parent 1: prio 1 u32 match ip sport $port 0xffff flowid 1:1
            docker_container_internal_netns_exec "$CONTAINER_ID" \
                tc filter add dev "$IF" protocol ip parent 1: prio 1 u32 match ip dport $port 0xffff flowid 1:1
        done
        # send the rest to class 1:2 using matchall (we don't use 1:3)
        docker_container_internal_netns_exec "$CONTAINER_ID" \
            tc filter add dev "$IF" parent 1: prio 2 matchall classid 1:2
        # add the tbf qdisc to class 1:2
        docker_container_internal_netns_exec "$CONTAINER_ID" \
            tc qdisc add dev "$IF" parent 1:2 handle 20: tbf burst 5kb latency 50ms $UPLINK_TBF_OPTIONS
    fi

done < <(get_el_containers)

