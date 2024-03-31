#/bin/sh

while read -r pid ppid comm
do
    if [ ! -z $pid ]
    then
        echo "kill $pid"
        kill -9 $pid
    fi
done <<< $(./show_filters.sh)
