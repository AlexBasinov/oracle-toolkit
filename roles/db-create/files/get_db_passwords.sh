#!/bin/bash

set -euo pipefail

SYS_SECRET="$1"
SYSTEM_SECRET="$2"

sys_pass=$(gcloud secrets versions access latest --secret="${SYS_SECRET}" --quiet)
system_pass=$(gcloud secrets versions access latest --secret="${SYSTEM_SECRET}" --quiet)

echo -e "${sys_pass}\n${system_pass}"
