#!/usr/bin/env python
import csv
import sys
import re

# Usage:
#
# $ cd $PGDATA/pg_xlog
# $ pg_xlogdump 000000010000000000000017 > dump.txt
#
# $ ./pg_xlogdump2csv.py dump.txt > 000000010000000000000017.csv
#
# Example output:
#
# "Heap","7","53,","1869820,","0/170525B0,","0/17052568,","LOCK xid 1869820: off 64 LOCK_ONLY EXCL_LOCK KEYS_UPDATED , blkref #0: rel 1663/16471/16472 blk "
# "Heap","14","71,","1869820,","0/170525E8,","0/170525B0,","HOT_UPDATE off 64 xmax 1869820KEYS_UPDATED ; new off 176 xmax 1869820, blkref #0: rel 1663/16471/16472 blk "
#
# Load table definition:
#
# $ psql -f xlogdump.sql
#
# From interactive psql session:
#
# (Before trigger fills in relation name as convenience here -- assumes WAL
# records originated in same database as that used to load records):
#
# postgres=# copy xlogdump_records (rmgr, len_rec, len_tot, tx, r_lsn, prev_lsn, descr) from '/someplace/pgdata/pg_xlogdump/000000010000000000000017.csv' with (format csv);
# COPY 150960

f = open(sys.argv[1], 'r')

writer = csv.writer(sys.stdout, quoting=csv.QUOTE_ALL)
for i in f:
    l = re.split('[ \t\n\r\f\v,]+', i, flags=re.IGNORECASE)
    rmgr = l[1]
    len_rec = re.sub("[^0-9]", "", l[4])
    len_tot = l[5]
    tx = l[7]
    lsn = l[9]
    prev = l[11]
    desc = ""
    for j in l[13:]:
        desc += j + " "
    writer.writerow([rmgr, len_rec, len_tot, tx, lsn, prev, desc])
