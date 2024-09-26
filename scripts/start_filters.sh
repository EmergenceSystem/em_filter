#!/bin/sh
#
config_file="$HOME/.config/emergence/filters"
PWD=$PWD
SLEEP=1

if [ ! -f "$config_file" ]; then
    echo "File $config_file not found."
    exit 1
fi

echo "Starting filters :"

while IFS= read -r line; do
    if [[ -n "$line" && "$line" != "#"* ]]; then
        echo "$SEP $line"
        cd $line
        cargo run >/dev/null 2>/dev/null &
        sleep $SLEEP
    fi
done < "$config_file"

cd $PWD
