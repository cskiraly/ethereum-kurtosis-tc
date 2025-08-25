#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
. "$SCRIPT_DIR/core.sh"
. "$SCRIPT_DIR/docker-common.sh"
. "$SCRIPT_DIR/tc-common.sh"

# get port from labels for selected services
kurtosis_container_get_ports() {
    CONTAINER_ID="$1"
    shift
    SERVICES="$@"
    SERVICE_PORTS=$(docker inspect --format='{{(index .Config.Labels "com.kurtosistech.ports")}}' "$CONTAINER_ID")
    # the format we get is like "rpc:8545/TCP,ws:8546/TCP,metrics:9001/TCP/http,tcp-discovery:32000/TCP,udp-discovery:32000/UDP,engine-rpc:8551/TCP"
    for SERVICE in $SERVICES; do
        PORT=$(echo "$SERVICE_PORTS" | grep -oP "(^|,)$SERVICE:\K\d+" | head -n 1)
        # if [ -z "$PORT" ]; then
        #     echo "Warning: No port found for container $CONTAINER_ID, service $SERVICE" >&2
        # fi
        PORTS="$PORTS $PORT"
    done
    echo "$PORTS"
}

# get ports from labels for all services, except the named ones
# TODO: handle transports
kurtosis_container_get_ports_except() {
    CONTAINER_ID="$1"
    shift
    EXCLUDED_SERVICES="$@"

    SERVICE_PORTS=$(docker inspect --format='{{(index .Config.Labels "com.kurtosistech.ports")}}' "$CONTAINER_ID")
    # the format we get is like "rpc:8545/TCP,ws:8546/TCP,metrics:9001/TCP/http,tcp-discovery:32000/TCP,udp-discovery:32000/UDP,engine-rpc:8551/TCP"
    # split the string to service, port tuples
    IFS=',' read -ra SPA <<< "$SERVICE_PORTS"
    for SP in "${SPA[@]}"; do
        SERVICE_NAME=$(echo "$SP" | cut -d':' -f1)
        SERVICE_PORT=$(echo "$SP" | cut -d':' -f2 | cut -d'/' -f1)

        # Check for exact match in excluded services
        if [[ ! " $EXCLUDED_SERVICES " =~ (^| )"$SERVICE_NAME"( |$) ]]; then
            PORTS="$PORTS $SERVICE_PORT"
        fi
    done
    echo "$PORTS"
}

# get id of all EL containers
get_el_containers() {
    docker ps -q --filter "name=^el-"
}

# get id of all CL containers
get_cl_containers() {
    docker ps -q --filter "name=^cl-"
}

get_containers_by_pattern() {
    docker ps -q --filter "name=$1"
}

echo "EL containers:"
get_el_containers

echo "CL containers:"
get_cl_containers

#process command line arguments
# Options
# -e: apply to EL containers
# -c: apply to CL containers
# -i: include also containers with this pattern in their name (e.g., ^el-0*1)
# --delay: set one way delay (e.g., 50ms)
# --loss: set loss (e.g., 1%)
# --corrupt: set corrupt (e.g., 0.1%)
# --duplicate: set duplicate (e.g., 0.1%)
# --reorder: set reorder (e.g., 0.1%)
# --downlink: set downlink rate (e.g., 50mbit)
# --uplink: set uplink rate
# --help: show this help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -e, --el                  Apply to EL containers"
    echo "  -c, --cl                  Apply to CL containers"
    echo "  -i, --include PATTERN     Include containers with this pattern in their name"
    echo "  -d, --delete              Remove traffic control"
    echo "  --delay DELAY             Set delay (e.g., 50ms)"
    echo "  --loss LOSS               Set loss (e.g., 1%)"
    echo "  --corrupt CORRUPT         Set corrupt (e.g., 0.1%)"
    echo "  --duplicate DUPLICATE     Set duplicate (e.g., 0.1%)"
    echo "  --reorder REORDER         Set reorder (e.g., 0.1%)"
    echo "  --downlink DOWNLINK       Set downlink rate (e.g., 50mbit)"
    echo "  --uplink UPLINK           Set uplink rate (e.g., 20mbit)"
    echo "  --help                    Show this help message"
}

NETM_OPTIONS=
DOWNLINK_TBF_OPTIONS=
UPLINK_TBF_OPTIONS=
OPTIONS_LOG=

# Parse command line arguments using getopts
while getopts "eci:d-:" opt; do
    case $opt in
        e) EL_CONTAINERS=true ;;
        c) CL_CONTAINERS=true ;;
        i) INCLUDE_PATTERN="$OPTARG" ;;
        d) DELETE=true ;;
        -)
            case $OPTARG in
                el) EL_CONTAINERS=true ;;
                cl) CL_CONTAINERS=true ;;
                include=*) INCLUDE_PATTERN=${OPTARG#*=} ;;
                delay=*) NETM_OPTIONS+="delay ${OPTARG#*=} " ;;
                loss=*) NETM_OPTIONS+="loss ${OPTARG#*=} " ;;
                corrupt=*) NETM_OPTIONS+="corrupt ${OPTARG#*=} " ;;
                duplicate=*) NETM_OPTIONS+="duplicate ${OPTARG#*=} " ;;
                reorder=*) NETM_OPTIONS+="reorder ${OPTARG#*=} " ;;
                downlink=*) DOWNLINK_TBF_OPTIONS="rate ${OPTARG#*=} " ;;
                uplink=*) UPLINK_TBF_OPTIONS="rate ${OPTARG#*=} " ;;
                help) show_help; exit 0 ;;
                *) echo "Unknown option: $OPTARG"; show_help; exit 1 ;;
            esac
            ;;
        *)
            echo "Unknown option: -$opt"
            show_help
            exit 1
            ;;
    esac
done

# select containers based on options
CONTAINER_IDS=""
if [ -z "$EL_CONTAINERS" ] && [ -z "$CL_CONTAINERS" ] && [ -z "$INCLUDE_PATTERN" ]; then
    echo "Error: No containers selected. Use -e, -c, or -i options."
    exit 1
fi
if [ "$EL_CONTAINERS" = true ]; then
    CONTAINER_IDS+="$(get_el_containers) "
fi
if [ "$CL_CONTAINERS" = true ]; then
    CONTAINER_IDS+="$(get_cl_containers) "
fi
if [ -n "$INCLUDE_PATTERN" ]; then
    CONTAINER_IDS+=$(get_containers_by_pattern "$INCLUDE_PATTERN")
fi
if [ -z "$CONTAINER_IDS" ]; then
    echo "No containers found matching the criteria."
    exit 0
fi

echo "NETM_OPTIONS: $NETM_OPTIONS"
echo "DOWNLINK_TBF_OPTIONS: $DOWNLINK_TBF_OPTIONS"
echo "UPLINK_TBF_OPTIONS: $UPLINK_TBF_OPTIONS"

if [ -z "$NETM_OPTIONS" ] && [ -z "$DOWNLINK_TBF_OPTIONS" ] && [ -z "$UPLINK_TBF_OPTIONS" ] && [ -z "$DELETE" ]; then
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

            if [ ! -z "$DOWNLINK_TBF_OPTIONS" ] || [ ! -z "$NETM_OPTIONS" ]; then
                EXCLUDE_PORTS=$(kurtosis_container_get_ports_except "$CONTAINER_ID" "tcp-discovery udp-discovery quic-discovery")
                echo "excluding ports from shaping: $EXCLUDE_PORTS"
                qdisc_filter_by_port "$NETWORK_INTERFACE_NAME" $EXCLUDE_PORTS
                if [ ! -z "$DOWNLINK_TBF_OPTIONS" ]; then
                    qdisc_tbf "$NETWORK_INTERFACE_NAME" $DOWNLINK_TBF_OPTIONS
                fi
                if [ ! -z "$NETM_OPTIONS" ]; then
                    qdisc_netm "$NETWORK_INTERFACE_NAME" $NETM_OPTIONS
                fi
                echo "Set ${OPTIONS_LOG} on $NETWORK_INTERFACE_NAME"
                echo "Controlling traffic of the container $(docker_container_get_name "$CONTAINER_ID") on $NETWORK_INTERFACE_NAME"
            fi
        done < <(echo -e "$NETWORK_INTERFACE_NAMES")
    done < <(echo -e "$CONTAINER_NETWORKS")

    # Set up egress (uplink) shaping
    docker_container_init_internal "$CONTAINER_ID"

    IF="eth0"
    # delete existing qdisc
    docker_container_internal_netns_exec "$CONTAINER_ID" \
        tc qdisc del dev "$IF" root

    if [ ! -z "$UPLINK_TBF_OPTIONS" ] || [ ! -z "$NETM_OPTIONS" ]; then
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
        # EXCLUDE_PORTS=$(kurtosis_container_get_ports "$CONTAINER_ID" "engine-rpc rpc ws metrics http ")
        EXCLUDE_PORTS=$(kurtosis_container_get_ports_except "$CONTAINER_ID" "tcp-discovery udp-discovery quic-discovery")
        echo "excluding ports from shaping: $EXCLUDE_PORTS"
        for port in $EXCLUDE_PORTS; do
            docker_container_internal_netns_exec "$CONTAINER_ID" \
                tc filter add dev "$IF" protocol ip parent 1: prio 1 u32 match ip sport $port 0xffff flowid 1:1
            docker_container_internal_netns_exec "$CONTAINER_ID" \
                tc filter add dev "$IF" protocol ip parent 1: prio 1 u32 match ip dport $port 0xffff flowid 1:1
        done
        # send the rest to class 1:2 using matchall (we don't use 1:3)
        docker_container_internal_netns_exec "$CONTAINER_ID" \
            tc filter add dev "$IF" parent 1: prio 2 matchall classid 1:2
        QDISC_HANDLE="parent 1:2 handle 20:"
        # add the tbf qdisc to class 1:2
        if [ ! -z "$UPLINK_TBF_OPTIONS" ]; then
            docker_container_internal_netns_exec "$CONTAINER_ID" \
                tc qdisc add dev "$IF" $QDISC_HANDLE tbf burst 5kb latency 50ms $UPLINK_TBF_OPTIONS
                QDISC_HANDLE="parent 20: handle 21:"
        fi
        # add delay on the uplink
        if [ ! -z "$NETM_OPTIONS" ]; then
            docker_container_internal_netns_exec "$CONTAINER_ID" \
                tc qdisc add dev "$IF" $QDISC_HANDLE netem $NETM_OPTIONS
        fi
    fi

done < <(echo -e "$CONTAINER_IDS")

