#!/bin/bash

START=$(date +%s.%N)
while true
do
	# Exclusion constraints, subxact variant
	#for clients in 8 16 64 128
	for clients in 128
	do
		echo "trying $clients clients:"
		perl count_upsert_subxact_exclusion.pl $clients 100 2>&1 | tee -a log
		if ((${PIPESTATUS[0]} != 0)); then
			END=$(date +%s.%N)
			DIFF=$(echo "$END - $START" | bc)
			echo "Exited from infinite loop due to unexpected error. Spent $DIFF time all iterations"
			exit 1
		fi
	done
done
