#!/bin/bash

if [[ -z "$APP_MODULE" ]]; then
    APP_MODULE="nodeselector_mutator:build_mutator()"
fi

if [[ -z "$APP_CONFIG" ]]; then
    APP_CONFIG="gunicorn_conf.py"
fi

gunicorn "$APP_MODULE" --access-logfile=- --config "$APP_CONFIG"