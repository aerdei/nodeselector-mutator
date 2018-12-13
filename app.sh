#!/bin/bash
set -eu

: "${APP_MODULE:="nodeselector_mutator:build_mutator()"}" "${APP_CONFIG:="gunicorn_conf.py"}"

gunicorn "$APP_MODULE" --access-logfile=- --config "$APP_CONFIG"
