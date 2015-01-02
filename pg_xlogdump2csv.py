#!/usr/bin/env python
import csv
import sys
import re

# Usage:
#
# $ cd $PGDATA
# $ pg_xlogdump 000000010000000000000017 > dump.txt
#
# $ ./pg_xlogdump2csv.py dump.txt > 000000010000000000000017.csv
#
# Example output:
#
# "Heap","7","53,","1869820,","0/170525B0,","0/17052568,","LOCK xid 1869820: off 64 LOCK_ONLY EXCL_LOCK KEYS_UPDATED , blkref #0: rel 1663/16471/16472 blk "
# "Heap","14","71,","1869820,","0/170525E8,","0/170525B0,","HOT_UPDATE off 64 xmax 1869820KEYS_UPDATED ; new off 176 xmax 1869820, blkref #0: rel 1663/16471/16472 blk "
#
# From psql:
#
# postgres=# create table my_xlogdump
# (
#     rmgr text not null,
#     len_rec numeric not null,
#     len_tot numeric not null,
#     tx xid not null,
#     r_lsn pg_lsn,
#     prev_lsn pg_lsn,
#     descr text not null
# );
# CREATE TABLE
#
# postgres=# copy my_xlogdump from '/path/to/000000010000000000000017.csv' with (format csv);
# COPY 150960
#
# postgres=# select * from my_xlogdump order by r_lsn;

f = open(sys.argv[1], 'r')

writer = csv.writer(sys.stdout, quoting=csv.QUOTE_ALL)
for i in f:
    l = re.split('[ ,]+', i, flags=re.IGNORECASE)
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
