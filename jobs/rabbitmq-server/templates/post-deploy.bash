#!/bin/bash -e

[ -z "$DEBUG" ] || set -x

PATH=/var/vcap/jobs/rabbitmq-server/bin:$PATH
HOME_DIR=/var/vcap/store/rabbitmq
OPERATOR_USERNAME_FILE="${HOME_DIR}/operator_administrator.username"

configure_users() {
  echo "Configuring RabbitMQ users ..."

  delete_guest
  [ -f $OPERATOR_USERNAME_FILE ] && delete_operator_admin
  create_operator_admin
  create_admin "$RMQ_BROKER_USERNAME" "$RMQ_BROKER_PASSWORD"
}

node-check "post-deploy"
cluster-check "post-deploy"
add-rabbitmqctl-to-path
