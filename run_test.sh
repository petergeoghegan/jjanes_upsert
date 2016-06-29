#!/bin/bash

while true
do
	# Regular B-Tree/unique indexes
	for clients in 8 16 64 128
	do
		echo "trying $clients clients:"
		perl count_upsert.pl $clients 1000 2>&1 | tee -a log
		if ((${PIPESTATUS[0]} != 0)); then
			echo "Exited from infinite loop due to unexpected error"
			exit 1
		fi
	done
done
