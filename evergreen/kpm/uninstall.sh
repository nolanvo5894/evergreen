#!/bin/sh
# KPM uninstall hook. On upgrade the app folder (and its settings) is kept.

echo "Deleting Evergreen scriptlet"
rm -f /mnt/us/documents/Evergreen.sh
if [ ! "$1" = "upgrade" ]; then
    echo "Deleting Evergreen folder"
    rm -rf /mnt/us/evergreen
fi
