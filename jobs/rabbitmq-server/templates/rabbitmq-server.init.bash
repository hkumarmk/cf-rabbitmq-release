#!/bin/bash -e
#
# rabbitmq-server RabbitMQ broker

# Note: if in rabbitmq-env.conf you change the location of the PID file,
# (probably by setting PID_FILE) things will continue to work, even from
# this file, as the rabbitmq-env script (sourced by all the rabbitmq
# commands) will equally source the rabbitmq-env.conf file and so
# PID_FILE will be reset every time, correctly). However, this file will
# still have the wrong definition of PID_FILE and so will create the
# "wrong" directory. Meh-ish.

[ -z "$DEBUG" ] || set -x

export PATH=/var/vcap/packages/erlang/bin:$PATH

RMQ_SERVER_PACKAGE=/var/vcap/packages/rabbitmq-server
DAEMON=${RMQ_SERVER_PACKAGE}/bin/rabbitmq-server
CONTROL=${RMQ_SERVER_PACKAGE}/bin/rabbitmqctl
USER=vcap
PID_FILE=/var/vcap/sys/run/rabbitmq-server/pid
HOME_DIR=/var/vcap/store/rabbitmq
OPERATOR_USERNAME_FILE="${HOME_DIR}/operator_administrator.username"
START_PROG=/usr/bin/setsid
JOB_DIR=/var/vcap/jobs/rabbitmq-server

LOG_DIR=/var/vcap/sys/log/rabbitmq-server
STARTUP_LOG="${LOG_DIR}"/startup_stdout.log
STARTUP_ERR_LOG="${LOG_DIR}"/startup_stderr.log

test -x "${DAEMON}"
test -x "${CONTROL}"
test -x "${START_PROG}"

RETVAL=0

# shellcheck disable=SC1090
[ -f "/var/vcap/store/rabbitmq/etc/default/rabbitmq-server" ] && . "/var/vcap/store/rabbitmq/etc/default/rabbitmq-server"
# shellcheck disable=SC1091
. /var/vcap/jobs/rabbitmq-server/etc/users
# shellcheck disable=SC1091
. /var/vcap/jobs/rabbitmq-server/etc/config

ensure_dir() {
    DIR=$1
    mkdir -p "${DIR}"
    chown -fR "${USER}":"${USER}" "${DIR}"
    chmod 755 "${DIR}"
}

ensure_dirs() {
    ensure_dir "$(dirname "${PID_FILE}")"
    ensure_dir "${HOME_DIR}"
}

remove_pid() {
    rm -f "${PID_FILE}"
}

delete_guest() {
    set +e
    "${CONTROL}" delete_user guest >> "${STARTUP_LOG}" 2>&1
    set -e
}

grant_permissions_for_all_vhosts() {
    set +e
    username=$1

    VHOSTS=$(${CONTROL} list_vhosts | tail -n +2)
    for vhost in $VHOSTS
    do
    "${CONTROL}" set_permissions -p "$vhost" "$username" ".*" ".*" ".*"  >> "${STARTUP_LOG}" 2>&1
    done
    true
    set -e
}

create_operator_admin() {
  if [ -n "$RMQ_OPERATOR_USERNAME" ]
  then
    echo "$RMQ_OPERATOR_USERNAME" > $OPERATOR_USERNAME_FILE
    create_admin "$RMQ_OPERATOR_USERNAME" "$RMQ_OPERATOR_PASSWORD"
  fi
}

create_admin() {
    username=$1
    password=$2

    set +e
    {
      "${CONTROL}" add_user "$username" "$password"
      "${CONTROL}" change_password "$username" "$password"
      "${CONTROL}" set_user_tags "$username" administrator
    } >> "${STARTUP_LOG}" 2>&1
    grant_permissions_for_all_vhosts "$username"
    set -e
}

delete_operator_admin() {
  set +e
  USERNAME=$(cat $OPERATOR_USERNAME_FILE)
  "${CONTROL}" delete_user "$USERNAME" >> "${STARTUP_LOG}" 2>&1
  set -e
  true
}

run_script() {
    local script
    script=$1
    echo "Starting ${script}"
    set +e
    "${script}" \
        1>> "${STARTUP_LOG}" \
        2>> "${STARTUP_ERR_LOG}" \
        0<&-
    RETVAL=$?
    set -e
    case "${RETVAL}" in
        0)
            echo "Finished ${script}"
            return 0
            ;;
        *)
            echo "Errored ${script}"
            RETVAL=1
            exit "${RETVAL}"
            ;;
    esac
}

prepare_for_upgrade () {
  echo "Preparing RabbitMQ for potential upgrade"
  local remote_nodes
  remote_nodes="$(cat /var/vcap/data/upgrade_preparation_nodes)"
  for remote_node in "${remote_nodes[@]}"; do
    /var/vcap/packages/rabbitmq-upgrade-preparation/bin/rabbitmq-upgrade-preparation \
      -rabbitmqctl-path "$CONTROL" \
      -node "$remote_node" \
      -new-rabbitmq-version "$(cat ${RMQ_SERVER_PACKAGE}/rmq_version)" \
      -new-erlang-version "$(cat ${RMQ_SERVER_PACKAGE}/erlang_version)" \
      1> >(tee -a "${LOG_DIR}"/upgrade.log) 2>&1
  done
}

start_rabbitmq () {
    ensure_dirs
    status_rabbitmq
    if [ "${RETVAL}" = 0 ]; then
        "${CONTROL}" eval 'list_to_integer(os:getpid()).' > $PID_FILE
        echo "RabbitMQ is currently running"
        if [ -f "$PID_FILE" ]
        then
          /var/vcap/jobs/rabbitmq-server/bin/node-check "rabbitmq-server.init" ||
          signal_monit_that_rabbitmq_node_is_not_healthy
        fi
    else
        RETVAL=0
        run_script "${JOB_DIR}/bin/setup.sh"
        run_script "${JOB_DIR}/bin/plugins.sh"
        prepare_for_upgrade
        echo "Starting RabbitMQ"
        track_rabbitmq_erlang_vm_pid_in_pid_file
        RABBITMQ_PID_FILE="${PID_FILE}" "${START_PROG}" "${DAEMON}" \
            >> "${STARTUP_LOG}" \
            2>> "${STARTUP_ERR_LOG}" \
            0<&- &

        RETVAL="$(wait_for_rabbitmq_clusterer_plugin_to_start_rabbitmq_app)"
        case "$RETVAL" in
            0)
                if ! /var/vcap/jobs/rabbitmq-server/bin/node-check "rabbitmq-server.init"
                then
                  signal_monit_that_rabbitmq_node_is_not_healthy
                  return
                fi

                configure_users

                if ! /var/vcap/jobs/rabbitmq-server/bin/cluster-check "rabbitmq-server.init"
                then
                  echo "RabbitMQ cluster is not healthy"
                  remove_pid
                  RETVAL=1
                  return
                fi

                echo "RabbitMQ cluster is healthy"

                ;;
            *)
                echo "RabbitMQ application failed to start while waiting for cluster to form"
                remove_pid
                RETVAL=1
                ;;
        esac
    fi
}

configure_users() {
  echo "Configuring RabbitMQ users ..."

  delete_guest
  [ -f $OPERATOR_USERNAME_FILE ] && delete_operator_admin
  create_operator_admin
  create_admin "$RMQ_BROKER_USERNAME" "$RMQ_BROKER_PASSWORD"
}

signal_monit_that_rabbitmq_node_is_not_healthy() {
  echo "RabbitMQ node is not healthy"

  echo 0 > "$PID_FILE"
}

track_rabbitmq_erlang_vm_pid_in_pid_file() {
  export RUNNING_UNDER_SYSTEMD=true
}

wait_for_rabbitmq_clusterer_plugin_to_start_rabbitmq_app() {
  local retval

  set +e
  "${CONTROL}" wait "${PID_FILE}" >> "${STARTUP_LOG}" 2>> "${STARTUP_ERR_LOG}"
  retval="$?"
  set -e
  echo "$retval"
}

status_rabbitmq() {
    set +e
    if [ "$1" != "quiet" ]; then
        "${CONTROL}" status 2>&1
    else
        "${CONTROL}" status > /dev/null 2>&1
    fi
    if [ $? != 0 ]; then
        RETVAL=3
    fi
    set -e
}

send_all_output_to_logfile() {
  exec 1> >(tee -a "${LOG_DIR}/init.log") 2>&1
}
send_all_output_to_logfile

case "$1" in
    start)
        ulimit -n "$RMQ_FD_LIMIT"
        start_rabbitmq
        ;;
    stop)
        echo "monit stop rabbitmq-server has no effect on RabbitMQ, please use bosh stop instead"
        ;;
    *)
        echo "Usage: $0 {start|stop}" >&2
        RETVAL=1
        ;;
esac

exit "${RETVAL}"
