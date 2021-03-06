#!/bin/bash -e

[ -z "$DEBUG" ] || set -x

JOB_DIR=/var/vcap/jobs/rabbitmq-server
PID_FILE=/var/vcap/sys/run/rabbitmq-server/pid
HOME_DIR=/var/vcap/store/rabbitmq
SERVICE_METRICS_DIR=/var/vcap/sys/log/service-metrics
ROOT_LOG_DIR=/var/vcap/sys/log
INIT_LOG_DIR=/var/vcap/sys/log/rabbitmq-server
HTTP_ACCESS_LOG_DIR="${INIT_LOG_DIR}"/management-ui
STARTUP_LOG="${INIT_LOG_DIR}"/startup_stdout.log
STARTUP_ERR_LOG="${INIT_LOG_DIR}"/startup_stderr.log
SHUTDOWN_LOG="${INIT_LOG_DIR}"/shutdown_stdout.log
SHUTDOWN_ERR_LOG="${INIT_LOG_DIR}"/shutdown_stderr.log
USER=vcap

source /var/vcap/packages/rabbitmq-common/ensure_dir_with_permissions

main() {
  remove_old_syslog_config

  ensure_dir_with_permissions "${ROOT_LOG_DIR}"
  ensure_dir_with_permissions "${INIT_LOG_DIR}"
  ensure_dir_with_permissions "${HTTP_ACCESS_LOG_DIR}"
  ensure_dir_with_permissions "$(dirname "${PID_FILE}")"
  ensure_dir_with_permissions "${HOME_DIR}"
  ensure_dir_with_permissions "${JOB_DIR}"
  ensure_dir_with_permissions "${SERVICE_METRICS_DIR}"
  ensure_log_files
  ensure_http_log_cleanup_cron_job
  ${JOB_DIR}/bin/ensure-rabbitmq-statsdb-restart-cron

  # shellcheck disable=SC1090
  . "${JOB_DIR}"/lib/prepare-for-upgrade.bash
  . "${JOB_DIR}"/lib/rabbitmq-config-vars.bash

  run_rabbitmq_upgrade_preparation_shutdown_cluster "$ERLANG_COOKIE" "${HOME_DIR}/.erlang.cookie" "$RABBITMQ_NODES_STRING"
}

remove_old_syslog_config() {
  rm -f /etc/rsyslog.d/00-syslog_forwarder.conf
  rm -f /etc/rsyslog.d/rabbitmq_syslog.conf
}

ensure_log_files() {
  touch "${STARTUP_LOG}"
  touch "${STARTUP_ERR_LOG}"
  touch "${SHUTDOWN_LOG}"
  touch "${SHUTDOWN_ERR_LOG}"
  chown "${USER}":"${USER}" "${INIT_LOG_DIR}"/startup*
  chown "${USER}":"${USER}" "${INIT_LOG_DIR}"/shutdown*
}

ensure_http_log_cleanup_cron_job() {
  cp "${JOB_DIR}/bin/cleanup-http-logs" /etc/cron.daily
}

main

