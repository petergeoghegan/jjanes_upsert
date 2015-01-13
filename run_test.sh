#!/bin/bash

while true
do
	for clients in 8 16 64 128
	do
		echo "trying $clients clients:"
		perl count_upsert.pl $clients 100000 2>&1 | tee -a log
		if ((${PIPESTATUS[0]} != 0)); then
			echo "rc $0"
			exit 1
		fi
	done
done
