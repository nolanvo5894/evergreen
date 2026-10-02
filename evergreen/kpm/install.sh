#!/bin/sh
# KPM install hook: runs from the unpacked package folder.

echo "Copying evergreen folder"
cp -rf ./evergreen /mnt/us/
rm -rf ./evergreen
echo "Copying Evergreen scriptlet"
if [ -f /mnt/us/documents/Evergreen.sh ]; then
    rm -f /mnt/us/documents/Evergreen.sh
    sleep 1
fi
cp -a ./scriptlets/Evergreen.sh /mnt/us/documents/Evergreen.sh
