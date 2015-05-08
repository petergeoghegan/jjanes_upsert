use strict;
use warnings;
use DBI;
use IO::Pipe;
use Storable;
use Data::Dumper;
use List::Util qw(shuffle);

# Timestamps with warnings are useful
$SIG{__WARN__} = sub { warn sprintf("[%s] ", scalar localtime), @_ };
$SIG{__DIE__}  = sub { die  sprintf("[%s] ", scalar localtime), @_, exit 1 };

## This is a stress tester for PostgreSQL crash recovery.

## It spawns a number of processes which all connect to the database
## and madly update a table until either the server crashes, or
## for a million updates (per process).

## Upon crash, each Perl process reports up to the parent how many times each value was updated
## plus which update was 'in flight' at the time of the crash. (Since we received neither an
## error nor a confirmation, the proper status of this in flight update is unknowable)

## The parent consolidates this info, waits for the database to recover, and verifies
## that the state of the database matches what we know it ought to be.

## first arg is number of processes (default 4), 2nd is number of updates per process
## (default 1_000_000), 3rd argument causes aborts when a certain discrepancy is seen

## Arranging for the server to crash is the obligation of the outer driving script (do.sh)
## and the accompanying instrumentation patch.

## I invoke this in an outer driving script and let both the Perl messages and the
## postmaster logs spool together into one log file.  That way it is easier to correlate
## server events with the client/Perl events chronologically.

## This generates a lot of logging info.  The tension here is that if you generate too much
## info, it is hard to find anomalies in the log file.  But if you generate too little info,
## then once you do find anomalies you can't figure out the cause.  So I error on the side
## of logging too much, and use command lines (memorialized below) to pull out the most
## interesting things.

## But with really high logging, the lines in the log file start
## getting garbled up, so back off a bit.  The commented out warn and elog things in this file
## and the patch file show places where I previously needed logging for debugging specific things,
## but decided I don't need it all of the time.  Leave the commented code as landmark for the future.

## look for odd messages in log file that originate from Perl
#fgrep ' line ' do.out |sort|uniq -c|sort -n|fgrep -v 'in flight'

## look at rate of incrementing over time, for Excel or SpotFire.
#grep -P '2014-05|^sum ' do.out |grep -P '^sum' -B1|perl -ne 'my @x=split/PDT/; print $x[0] and next if @x>1; print if /sum/' > ~/jj.txt

## check consistency between child and parent table: (the 10 here matches the 10 in 'if ($count->[0][0] % 10 == 0)'
## psql -c 'select abs(id), sum(count) from upsert_race_test_parent where count>0 group by abs(id) except select abs(p_id), sum(floor(count::float/10)) from upsert_race_test group by abs(p_id)'

my $SIZE=10_000;

## centralize connections to one place, in case we want to point to a remote server or use a password
sub dbconnect {
  my $dbh = DBI->connect("dbi:Pg:;host=127.0.0.1", "", "", {pg_server_prepare => 0, AutoCommit => 1, RaiseError=>1, PrintError=>0});
  return $dbh;
};

my %count;

while (1) {
  %count=();
  eval {
    my $dbh = dbconnect();
    eval { ## on multiple times through, the table already exists, just let it fail
         ## But if the table exists, don't pollute the log with errors
         $dbh->do(<<'END');
drop table if exists upsert_race_test;
create extension if not exists btree_gist;

CREATE TABLE upsert_race_test(
  index int,
  count int,
  EXCLUDE USING gist (index WITH =)
);
END
    };
    my $dat = $dbh->selectall_arrayref("select index, count from upsert_race_test");
    ## now that we insert on the fly as needed, there is no need
    ## for the 'clean out and init' step
    if (1 or @$dat == $SIZE) {
         $count{$_->[0]}=$_->[1] foreach @$dat;
    } else {
      warn "table not correct size, ", scalar @$dat unless @$dat==0;
      $dbh->do("truncate upsert_race_test");
      %count=();
      my $sth=$dbh->prepare("insert into upsert_race_test (index, count) values (?,0)");
      $dbh->begin_work();
      $sth->execute($_) foreach 1..$SIZE;
      $dbh->commit();
    };
    ## even the pause every 100 rounds to let autovac do its things is not enough
    ## because the autovac itself generates enough IO to trigger crashes so that it never completes,
    ## lead to wrap around shut down.  This should keep the vaccum load low enough to complete, at least some times
    ## $dbh->do("vacuum upsert_race_test") if rand()<0.1;
  };
  last unless $@;
  warn "Failed with $@, trying again";
  sleep 1;
};
warn "init done";

my @child_pipe;
my $pipe_up;
foreach (1.. ((@ARGV and $ARGV[0]>0) ? $ARGV[0] : 4)) {
    my $pipe = new IO::Pipe;
    defined (my $fork = fork) or die "fork failed: $!";
    if ($fork) {
      push @child_pipe, {pipe => $pipe->reader(), pid => $fork};
    } else {
      $pipe_up=$pipe->writer();
      @child_pipe=();
      last;
    };
};

#warn "fork done";

if (@child_pipe) {
  #warn "in harvest";
  my %in_flight;
  my $abs;
  ### harvest children data, which consists of the in-flight item, plus a hash with the counts of all confirmed-committed items
  local $/;
  foreach my $handle ( @child_pipe ) {
    my $data=Storable::fd_retrieve($handle->{pipe});
    $in_flight{$data->[0]}=() if defined $data->[0];
    $abs+=$data->[2];
    while (my ($k,$v)=each %{$data->[1]}) {
       $count{$k}+=$v;
    };
    close $handle->{pipe} or die "$$ closing child failed with bang $!, and question $?";
    my $pid =waitpid $handle->{pid}, 0 ;
    die "$$: my child $pid exited with non-zero status $?" if $?;
  };
  #warn "harvest done";
  my ($dat,$dat2);
  foreach (1..300) {
       sleep 1;
       ## used to do just to the connect in the eval loop,
       ## but sometimes the database crashed again during the
       ## query, so do it all in the loop
       eval {
         warn "summary attempt $_" if $_>1;
         my $dbh = dbconnect();
         ## detect wrap around shutdown (actually not shutdown, but read-onlyness) and bail out
         ## need to detect before $dat is set, or else it won't trigger a Perl fatal error.
         $dbh->do("create temporary table aldjf (x serial)");
         $dat = $dbh->selectall_arrayref("select index, count from upsert_race_test");
         ## the sum used to be an indicator of the amount of work done, but
         ## now that the increment can be either positive or negative, it no longer is.
         warn "sum is ", $dbh->selectrow_array("select sum(count) from upsert_race_test"), "\n";
         warn "count is ", $dbh->selectrow_array("select count(*) from upsert_race_test"), "\n";
         # try to force it to walk the index to get to each row, so corrupt indexes are detected
         # (Without the "where index is not null", it won't use an index scan no matter what)
         $dat2 = $dbh->selectall_arrayref("set enable_seqscan=off; select index, count from upsert_race_test where index is not null");
       };
       last unless $@;
       warn $@;
  };
  die "Database didn't recover even after 5 minutes, giving up" unless $dat2;
  ## don't do sorts in SQL because it might change the execution plan
  my $keep = Dumper($dat,$dat2);
  @$dat=sort {$a->[0]<=>$b->[0]} @$dat;
  @$dat2=sort {$a->[0]<=>$b->[0]} @$dat2;
  my $dodie=0;
  foreach (@$dat) {
    $_->[0] == $dat2->[0][0] and $_->[1] == $dat2->[0][1] or die "seq scan doesn't match index scan  $_->[0] == $dat2->[0][0] and $_->[1] == $dat2->[0][1] $keep"; shift @$dat2;
    no warnings 'uninitialized';
    warn "For tuple with index value $_->[0], $_->[1] != $count{$_->[0]}", exists $in_flight{$_->[0]}? " in flight":""  if $_->[1] != $count{$_->[0]};
    if ($_->[1] != $count{$_->[0]}) {
       #bring down the system now, before autovac destroys the evidence
       $dodie = 1;
    };
    delete $count{$_->[0]};
  };
  ## If it has a count of 0, it may or may not have been deleted, either way is acceptable
  delete $count{$_} foreach grep {$count{$_}==0} keys %count;
  ## If it has a count of 0 (or was in flight and so might truly have been zero), it may or may not have been deleted, either way is acceptable
  delete @count{keys %in_flight};
  warn "Left over in %count: @{[%count]}" if %count;
  #die if %count and defined $ARGV[2];
  die if %count;
  if ($dodie != 0) {
	  die
  }
  warn "normal exit at ", time() ," after $abs items processed";
  exit;
};


my %h; # how many time has each item been incremented
my $i; # in flight item which is not reported to have been committed
my $abs; # since increment are now both pos and neg, this is the absolute number of them.

eval {
  ## do the dbconnect in the eval, in case we crash when some children are not yet
  ## up.  The children that fail to connect in the first place still
  ## need to send the empty data to nstore_fd, or else fd_retieve fatals out.
  my $dbh = dbconnect();
  # $dbh->do("SET SESSION synchronous_commit = false");

  # Use of redundant WHERE clause provides additional assurances that the tuple
  # locked and updated is actually the correct one.
  my $sth=$dbh->prepare('insert into upsert_race_test as target (index, count) values ($2,$1) on conflict
              do update set count=TARGET.count + EXCLUDED.count
              where TARGET.index = EXCLUDED.index
              returning count');
  my $del=$dbh->prepare('delete from upsert_race_test where index=? and count=0');
  my $getxid=$dbh->prepare('select txid_current()');
  #my $ins=$dbh->prepare('insert into upsert_race_test (index, count) values (?,0)');
  foreach (1..($ARGV[1]//1e6)) {
    $i=1+int rand($SIZE);
    my $d = rand() < 0.5 ? -1 : 1;
    my $count = $dbh->selectall_arrayref($sth,undef,$d,$i);
    my $xid;
    if ((@$count != 1) || ( not length $count->[0][0])) {
      $getxid->execute();
      $xid = $getxid->fetchrow();
      }
    @$count == 1 or die "update did not update 1 row: key $i updated '@$count'. xid was: $xid";
    $del->execute($i) if $count->[0][0]==0;
    warn "xid of uninitialized count inserter of index value $i was ", $xid if ( not length $count->[0][0] );
    $h{$i}+=$d;
    undef $i;
    $abs++;
  };
  $@ =~ s/\n/\\n /g if defined $@;
  warn "child exit ", $dbh->state(), " $@" if length $@;
};
$@ =~ s/\n/\\n /g if defined $@;
warn "child abnormal exit $@" if length $@;

Storable::nstore_fd([$i,\%h,$abs],$pipe_up);
close $pipe_up or die "$! $?";
