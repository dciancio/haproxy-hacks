#!/usr/bin/env bash

set -eu

docker_pod_prefix=docker-nginx-

function docker_pods() {
    docker ps --no-trunc --filter name=^/${docker_pod_prefix} --format '{{.Names}}'
}
