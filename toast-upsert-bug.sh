#!/bin/bash
psql -c "create table if not exists upsert_toast_bug(foo text, bar text, data jsonb, primary key(foo, bar));"
while true
do
	psql -c "truncate upsert_toast_bug"
	pgbench -f toast-upsert-bug.script.pgbench -n -s 1000 -T 5 -j 4 -c 8
done
