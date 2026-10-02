#!/bin/sh

set -e
cd /mnt/us/
set +e
UNPACK_DIR=$(pwd) sh evergreen/koreader.sh "$@"
