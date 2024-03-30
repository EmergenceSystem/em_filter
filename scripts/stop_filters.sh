#/bin/sh

while read -r pid ppid comm
do
    if [ ! -z $pid ]
    then
        echo "kill $pid"
        kill -9 $pid
    fi
done <<< $(ps -ef -eo pid,ppid,comm | grep filter | grep -v grep)
