echo $HOSTNAME

TMPDATA=/tmp/data2
INST=/home/pg/pgsql/

on_exit() {
  echo "Cleaning up"
  $INST/bin/pg_ctl -D $TMPDATA stop -m immediate -w
  # rm -r $TMPDATA
  exit 0
}

on_error() {
  echo "Cleaning up"
  $INST/bin/pg_ctl -D $TMPDATA stop -m immediate -w
  # don't clean up, to preserve for forensic analysis.
  # rm -r $TMPDATA/
  exit 1
};

trap 'on_exit' USR2;
trap 'on_exit' INT;

# Unlimited sized core dumps
ulimit -c unlimited

$INST/bin/pg_ctl -D $TMPDATA stop -m immediate -w
rm -r $TMPDATA
$INST/bin/initdb -k -D $TMPDATA || exit

cat <<END  >> $TMPDATA/postgresql.conf
##  Jeff's changes to config for use with recovery stress testing
wal_level = archive
wal_keep_segments=20  ## preserve some evidence
##  Crashes are driven by checkpoints, so we want to do them often
checkpoint_segments = 1
checkpoint_timeout = 30s
checkpoint_warning = 0
#archive_mode = on
## There is a known race condition that sometimes causes auto restart to fail when archiving is on.
## that is annoying, so turn it off unless we specifically want to test the on condition.
archive_mode = off
archive_command = 'echo archive_command %p %f `date`'       # Don't actually archive, just make pgsql think we are
archive_timeout = 30
log_checkpoints = on
log_autovacuum_min_duration=0
autovacuum_naptime = 10s
log_line_prefix = '%p %i %m:'
restart_after_crash = on
## Since we crash the PG software, not the OS, fsync does not matter as the surviving OS is obligated to provide a
## consistent view of the written-but-not-fsynced data even after PG restarts.  Turning it off gives more
## testing per unit of time.
fsync=off
log_error_verbosity = verbose
JJ_vac=1
shared_preload_libraries = 'pg_stat_statements'
END

## the extra verbosity is often just annoying, turn it off when not needed.
## (but leave them turned on above, so I remember what settings I need when
## I do need it.

cat <<END  >> $TMPDATA/postgresql.conf
log_error_verbosity = default
log_checkpoints = off
log_autovacuum_min_duration=-1
JJ_vac=0
END

$INST/bin/pg_ctl -D $TMPDATA start -w || exit
$INST/bin/createdb
$INST/bin/psql -c 'create extension pageinspect'

# while (true) ; do  psql -c "\dit+ ";  sleep 5; done &
for g in `seq 1 1000` ; do
  $INST/bin/pg_ctl -D $TMPDATA restart -o "--ignore_checksum_failure=0 --JJ_torn_page=6000 --JJ_xid=0" -w
  echo JJ starting loop $g;
  for f in `seq 1 100`; do
    #$INST/bin/psql -c 'SELECT datname, datfrozenxid, age(datfrozenxid) FROM pg_database;';
    ## on_error is needed to preserve database for inspection.  Otherwise autovac will destroy evidence.
    perl count_upsert.pl 8 || on_error;
  done;
  echo JJ ending loop $g;
  ## give autovac a chance to run to completion
  # need to disable crashing, as sometimes the vacuum itself triggers the crash
  $INST/bin/pg_ctl -D $TMPDATA restart -o "--ignore_checksum_failure=0 --JJ_torn_page=0 --JJ_xid=40" -w || (sleep 5; \
  $INST/bin/pg_ctl -D $TMPDATA restart -o "--ignore_checksum_failure=0 --JJ_torn_page=0 --JJ_xid=40" -w || on_error;)
  ## trying to get autovac to work in the face of consistent crashing
  ## is just too hard, so do manual vacs unless autovac is specifically
  ## what you are testing.
  $INST/bin/vacuumdb -a -F || on_error;
  ## or sleep a few times in the hope autovac can get it done, if you want to test that.
  #$INST/bin/psql -c 'select pg_sleep(120)' || (sleep 5; $INST/bin/psql -c 'select pg_sleep(120)') || (sleep 5; $INST/bin/psql -c 'select pg_sleep(120)')## give autovac a chance to do its thing
  echo JJ ending sleep after loop $g;
done;
on_exit
