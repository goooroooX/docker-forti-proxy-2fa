#!/bin/bash

# exit on any script failure
set -e -o pipefail

trap "echo The script is terminated by SIGINT; exit" SIGINT
trap "echo The script is terminated by SIGTERM; exit" SIGTERM
trap "echo The script is terminated by SIGKILL; exit" SIGKILL

if [ "$ENTRYDEBUG" == "TRUE" ]; then
    # print shell input lines as they are read
    set -v
fi

# ensure the ppp device exists
[ -c /dev/ppp ] || su-exec root mknod /dev/ppp c 108 0

# make folder for logs (available outside container)
export LOGS_FOLDER=${VPN_2FA_DIR}/logs
rm -rf ${LOGS_FOLDER}
mkdir -p ${LOGS_FOLDER}


file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(<"${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

check_required_variabled() {
    if [ -z "$VPN_ADDR" -o -z "$VPN_USER" -o -z "$VPN_PASS" ]; then
        echo "`date` [INIT] Variables VPN_ADDR, VPN_USER and VPN_PASS must be set."
        exit 1
    fi

    if [ ! -d "$VPN_2FA_DIR" ]; then
        echo "`date` [INIT] The 2FA directory not exist. Please fill variable VPN_2FA_DIR with valid directory."
        exit 1
    fi
}

docker_env_setup() {
    file_env 'VPN_ADDR'
    file_env 'VPN_USER'
    file_env 'VPN_PASS'
    file_env 'VPN_2FA_DIR' '/tmp/2fa/'
    file_env 'VPN_2FA_FILE' '/tmp/2fa/2fa.txt'
    file_env 'ENABLE_IPTABLES_LEGACY'
    file_env 'ENABLE_PORT_FORWARDING'
    file_env 'SOCKS_PROXY_PORT' 8443
}

port_forwarding_setup() {
    # generate regex search string
    r="^"                          # required start of variable name
    r="${r}\(PORT_FORWARD\|REMOTE_ADDR\)[^=]*="  # Required variable name
    r="${r}\(\(tcp\|udp\):\)\?"    # optional tcp or udp
    r="${r}\(\(\d\{1,5\}\):\)\?"   # optional LOCAL_PORT
    r="${r}[a-zA-Z0-9.-]\+"        # required REMOTE_HOST (ip or hostname)
    r="${r}:\d\{1,5\}"             # required REMOTE_PORT
    r="${r}$"                      # required end of variable contents

    # create a space separated list of forwarded ports. Pause immediate script
    # termination on non-zero exits to permit use without port forwarding.
    set +e
    forwards=$(
      env \
      | grep "${r}" \
      | cut -d= -f2-
    )
    set -e

    # remove our old socat entries from ip-up
    sed '/^socat/d' -i /etc/ppp/ip-up

    # iterate over all REMOTE_ADDR.* environment variables and create ppp ip-up 
    # scripts
    for forward in ${forwards}; do

      # replace colons with spaces add them into a bash array
      colons=$(echo "${forward}" | grep -o ':' | wc -l)

      if [ "${colons}" -eq "3" ]; then
        PROTOCOL=$(echo "${forward}" | cut -d: -f1)
        LOCAL_PORT=$(echo "${forward}" | cut -d: -f2)
        REMOTE_HOST=$(echo "${forward}" | cut -d: -f3)
        REMOTE_PORT=$(echo "${forward}" | cut -d: -f4)

      elif [ "${colons}" -eq "2" ]; then
        PROTOCOL="tcp"
        LOCAL_PORT=$(echo "${forward}" | cut -d: -f1)
        REMOTE_HOST=$(echo "${forward}" | cut -d: -f2)
        REMOTE_PORT=$(echo "${forward}" | cut -d: -f3)

      elif [ "${colons}" -eq "1" ]; then
        PROTOCOL="tcp"
        LOCAL_PORT="1111"
        REMOTE_HOST=$(echo "${forward}" | cut -d: -f1)
        REMOTE_PORT=$(echo "${forward}" | cut -d: -f2)

      else
        echo '`date` [INIT] ERROR: unrecognized PORT_FORWARD(*) value: "%s"\n' "${address}" >&2
        exit 1
      fi

      # use ppp's ip-up script to start the socat tunnels. In testing, this works 
      # well with one exception being hostname resolution doesnt happen within the
      # VPN.
      # for future attemps at solving this issue: dig/drill resolve properly after
      # VPN is established whereas `getent hosts` and whatver ping/ssh use do not.
      # it seems potentially related to musl and would be worth testing if this 
      # docker image should base of debian instead of alpine.
      echo "socat ${PROTOCOL}-l:${LOCAL_PORT},fork,reuseaddr ${PROTOCOL}:${REMOTE_HOST}:${REMOTE_PORT} &" \
          >> "/etc/ppp/ip-up"
      echo "`date` [INIT] INFO: -> socat {LOCAL_PORT}->${REMOTE_HOST}:${REMOTE_PORT}"
    done
}

start_proxy() {
    PROXY_LOG=${LOGS_FOLDER}/proxy.log
    rm -f $PROXY_LOG
    echo "`date` [INIT] Starting glider proxy on port ${SOCKS_PROXY_PORT}."
    /usr/bin/glider -verbose -listen :${SOCKS_PROXY_PORT} &>$PROXY_LOG & disown
    echo "`date` [INIT] -> proxy log: ${PROXY_LOG}"
     
    if [ $? -eq 0 ]; then
        echo "`date` [INIT] OK proxy started."
    else
        echo "`date` [INIT] ERROR while starting proxy! Exiting now."
        exit 1
    fi
}

run_2fa_listener() {
    rm -f "$VPN_2FA_FILE"
    touch "$VPN_2FA_FILE"
    chmod 777 "$VPN_2FA_FILE"
    
    echo "`date` [INIT] Checking iptables..."
    if [ -n "$ENABLE_IPTABLES_LEGACY" ]; then
        echo "`date` [INIT] Using 'iptables-legacy' for masquerading."
        LEGACY_CMD=$(iptables --version | grep legacy)
        if [ ! -z "$VPN_2FA_DIR" ]; then
            echo "`date` [INIT] Legacy iptables already enabled."
        else
            echo "`date` [INIT] Running update-alternatives"
            update-alternatives --set iptables /usr/sbin/iptables-legacy
            if [ $? -eq 0 ]; then
                echo "`date` [INIT] OK update-alternatives"
            else
                echo "`date` [INIT] ERROR update-alternatives"
            fi
        fi
    else
        echo "`date` [INIT] NOT enabling 'iptables-legacy' for masquerading."
    fi
    
    echo "`date` [INIT] Setting up masquerading with iptables..."
    # setup masquerade, to allow the container to act as a gateway
    for iface in $(ip a | grep eth | grep inet | awk '{print $2}'); do
        iptables -t nat -A POSTROUTING -s "$iface" -j MASQUERADE
        if [ $? -eq 0 ]; then
            echo "`date` [INIT] -> OK ipdatbles"
        else
            echo "`date` [INIT] -> ERROR iptables"
        fi
    done
    echo "`date` [INIT] Iptables setup DONE"
    echo "`date` [INIT] Killing any running listeners."
    pkill -15 -f -e "inotifywait" || echo "`date` [INIT] No process to kill."
    sleep 2
    echo "`date` [INIT] Looping listener execution."
    while [ true ]; do
        echo "`date` [INIT] 2FA Token Listener Start. Waiting for new token."
        /usr/bin/inotifywait.sh
        echo "`date` [INIT] 2FA Token Listener Terminated!"
        sleep 10
    done
}

_main() {
    check_required_variabled
    docker_env_setup
    start_proxy
    if [ -n "$ENABLE_PORT_FORWARDING" ]; then
        echo "`date` [INIT] Setting up port forwarding..."
        port_forwarding_setup
    else
        echo "`date` [INIT] Port forwarding is NOT enabled."
    fi
    # run listener that will monitoring for 2FA file changes
    run_2fa_listener
}

_main "$@"