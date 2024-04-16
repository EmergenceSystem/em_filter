#/bin/sh

while read -r pid ppid comm
do
    if [ ! -z $pid ]
    then
        echo "$pid $ppid $comm"
    fi
done <<< $(ps -eo pid,ppid,command | grep filter | grep -v grep)
