#!/usr/bin/env bash

echo "`date` [LISTENER] INFO: Enabling inotifywait trap."

# inotifywait recursive folder processing (-r) is NOT enabled
# to avoid triggering on logs subfolder activity
inotifywait -qme CLOSE_WRITE,MOVED_TO,CREATE "${VPN_2FA_DIR}" |
while read -r directory action file; do
  echo "`date` [$action] --> $file"
  if [[ "$(basename $file)" = "$(basename $VPN_2FA_FILE)" ]]; then
    VPN_2FA_TOKEN=$(head -1 $VPN_2FA_FILE | tr -d '[:space:]')
    export VPN_2FA_TOKEN

    # check for empty file
    if [ -z "$VPN_2FA_TOKEN" ]; then
      echo "`date` [LISTENER] ERROR: 2FA file looks empty!"
      echo "`date` [LISTENER] INFO: Waiting for new 2FA code."
      sleep 1
      continue
    fi

    # check for wrong number of symbols
    token_len=${#VPN_2FA_TOKEN}
    if [[ $token_len -ne 6 ]]; then
      echo "`date` [LISTENER] ERROR: Wrong number of symbols ($token_len) in 2FA code - expecting six (6)."
      echo "`date` [LISTENER] ERROR: Skipping current code: $VPN_2FA_TOKEN"
      echo "`date` [LISTENER] INFO: Waiting for new 2FA code."
      sleep 1
      continue
    fi

    # check for all-numbers 2FA code
    # 1 is added to avoid numbers detection issue with leading zero
    if ! [[ "1$VPN_2FA_TOKEN" -eq "1$VPN_2FA_TOKEN" ]] 2>/dev/null; then
      echo "`date` [LISTENER] ERROR: 2FA code is NOT all-numbers! Looping..."
      echo "`date` [LISTENER] INFO: Waiting for new 2FA code."
      sleep 1
      continue
    fi

    echo "`date` [LISTENER] INFO: Terminating all running VPN client instances."
    pkill -15 -f -e "openfortivpn" || echo "`date` [LISTENER] No process to kill."
    sleep 3

    echo "`date` [LISTENER] INFO: Make sure we are good and all processes are ended."
    result=`ps -ef | grep -v 'grep' | grep 'openfortivpn'`
    if [[ "$result" != "" ]];then
        echo "`date` [LISTENER] ERROR: Failed to KILL all 'openfortivpn' instances! Cannot continue."
        echo "`date` [LISTENER] INFO: Waiting for new 2FA code."
        sleep 1
        continue
    fi
    
    # get a digest for server
    echo "`date` [LISTENER] INFO: Getting fingerprint (trusted certificate) from ${VPN_ADDR}."
    DIGEST=`echo | openssl s_client -connect ${VPN_ADDR} 2>/dev/null | openssl x509 -outform der | sha256sum |  awk '{ print $1 }'`
    if [ -z "$DIGEST" ]; then
        echo "`date` [LISTENER] ERROR: DIGEST looks empty!"
        echo "`date` [LISTENER] INFO: Waiting for new 2FA code."
        sleep 1
        continue
    else
        echo "`date` [LISTENER] INFO: DIGEST=${DIGEST}"
    fi
    sleep 0.5
    
    # and finally exec a new one
    echo "`date` [LISTENER] INFO: Starting VPN."
    echo "====================================================="
    VPN_LOG=${LOGS_FOLDER}/vpn.log
    rm -f $VPN_LOG
    echo "`date` [LISTENER] INFO: VPN Log started." > $VPN_LOG
    CMD="/usr/bin/openfortivpn ${VPN_ADDR} -u ${VPN_USER} -p ${VPN_PASS} -o ${VPN_2FA_TOKEN} --trusted-cert ${DIGEST}" 
    eval "${CMD}" >> $VPN_LOG 2>&1 & disown
    echo "`date` [LISTENER] -> VPN log: ${VPN_LOG}"
    echo "`date` [LISTENER] INFO: Wait for 10 seconds to display VPN connection progress log."
    sleep 10
    echo "=== VPN LOG START ==="
    tail -n 20 $VPN_LOG
    echo "==== VPN LOG END ===="
    echo "====================================================="
    echo "`date` [LISTENER] INFO: Waiting for another 2FA token (VPN will restart)."
    continue
  fi

done
