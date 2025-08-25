#!/usr/bin/env bash
QDISC_ID=
QDISC_HANDLE=
tc_init() {
    QDISC_ID=1
    QDISC_HANDLE="root handle $QDISC_ID:"
}
qdisc_del() {
    tc qdisc show dev "$1" root | grep -q "noqueue" || tc qdisc del dev "$1" root
}
qdisc_next() {
    CLASS=$1
    QDISC_HANDLE="parent $QDISC_ID:$CLASS handle $((QDISC_ID+1)):"
    ((QDISC_ID++))
}
qdisc_filter_by_port() {
    IF="$1"
    shift
    exclude_ports="$@"
    # add a prio qdisc to split traffic, using
    # - class 1:1 for protected control traffic
    # - class 1:2 for shaped traffic
    # - class 1:3 not used.
    # Disable TOS based functionality.
    # Set up classes to exclude control and measurement traffic:
    # fef2243b0595   el-1-geth-lighthouse                     engine-rpc: 8551/tcp -> 127.0.0.1:32001        RUNNING
    #                                                         metrics: 9001/tcp -> http://127.0.0.1:32002
    #                                                         rpc: 8545/tcp -> 127.0.0.1:32003
    #                                                         tcp-discovery: 32000/tcp -> 127.0.0.1:32000
    #                                                         udp-discovery: 32000/udp -> 127.0.0.1:32000
    #                                                         ws: 8546/tcp -> 127.0.0.1:32004
    tc qdisc add dev "$IF" $QDISC_HANDLE prio
    # exclude engine-rpc, rpc, ws, metrics by sending to class 1:1
    # TODO: get ports from labels
    for port in $exclude_ports; do
        tc filter add dev "$IF" protocol ip parent 1: prio 1 u32 match ip sport $port 0xffff flowid 1:1
        tc filter add dev "$IF" protocol ip parent 1: prio 1 u32 match ip dport $port 0xffff flowid 1:1
    done
    # send the rest to class 1:2 using matchall (we don't use 1:3)
    tc filter add dev "$IF" parent 1: prio 2 matchall classid 1:2

    qdisc_next 2
}
# Following calls to qdisc_netm and qdisc_tbf are chained together
# http://man7.org/linux/man-pages/man8/tc-netem.8.html
qdisc_netm() {
    IF="$1"
    shift
    tc qdisc add dev "$IF" $QDISC_HANDLE netem $@
    qdisc_next
}
# http://man7.org/linux/man-pages/man8/tc-tbf.8.html
qdisc_tbf() {
    IF="$1"
    shift
    tc qdisc add dev "$IF" $QDISC_HANDLE tbf burst 5kb latency 50ms $@
    qdisc_next
}