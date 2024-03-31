#/bin/sh

while read -r pid ppid comm
do
    if [ ! -z $pid ]
    then
        echo "$pid $ppid $comm"
    fi
done <<< $(ps -eo pid,ppid,comm | grep filter | grep -v grep)
