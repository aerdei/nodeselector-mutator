#!/bin/bash
set -eu

gunicorn "${APP_MODULE:-nodeselector_mutator:build_mutator()}" --access-logfile=- --config "${APP_CONFIG:-gunicorn_conf.py}"
