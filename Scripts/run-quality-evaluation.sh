#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"
if (( $# == 0 )); then
    swift run -c release PoleQualityEvaluation 40
else
    swift run -c release PoleQualityEvaluation "$@"
fi
