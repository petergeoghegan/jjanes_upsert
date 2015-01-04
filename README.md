jjanes_upsert
=============

Utility to stress-test PostgreSQL "UPSERT" patch:

  https://commitfest.postgresql.org/action/patch_view?id=1564

Further details of patch:

  https://wiki.postgresql.org/wiki/UPSERT

Initial version by Jeff Janes, posted here:

http://www.postgresql.org/message-id/CAMkU=1wFcwBjJmgsiq8SwQb76OOORGzQE2xaCSODkOfZbGN3SA@mail.gmail.com

Dependencies
------------
contrib/pageinspect
contrib/pg_stat_statements (recommended)

Details
-------

Jeff Janes describes recreating a problem with approach #2 to value locking
using the script directly. Instructions:

Generally the problem will occur early on in the process, and if not then it
will not occur at all.  I think that is because the table starts out empty, and
so a lot of insertions collide with each other.  Once the table is more
thoroughly populated, most query takes the CONFLICT branch and therefore two
insertion-branches are unlikely to collide.

At its simplest, I just use the count_upsert.pl script and your patch and
forget all the rest of the stuff from my test platform.

So:

```
pg_ctl stop -D /tmp/data2; rm /tmp/data2 -r;
../torn_bisect/bin/pg_ctl initdb -D /tmp/data2;
../torn_bisect/bin/pg_ctl start -D /tmp/data2 -o "--fsync=off" -w ;
createdb;
perl count_upsert.pl 8 100000
```

A run of count_upsert.pl 8 100000 takes about 30 seconds on my machine (8
core), and if it doesn't create a problem then I just destroy the database and
start over.

The fsync=off is not important, I've seen the problem once without it.  I just
include it because otherwise the run takes a lot longer.

I've attached another version of the count_upsert.pl script, with some more
logging targeted to this particular issue.

The problem shows up like this:

```
init done at count_upsert.pl line 97.
sum is 1036
count is 9720
seq scan doesn't match index scan  1535 == 1535 and 1 == 6 $VAR1 = [
          [
            6535,
            -21
          ],
.....
```
(Thousands of more lines, as it outputs the entire table twice, once gathered
by seq scan, once by bitmap index scan).

The first three lines are normal, the problem starts with the "seq scan doesn't
match"...

In this case the first problem it ran into was that key 1535 was present once
with a count column of 1 (found by seq scan) and once with a count column of 6
(found by index scan).  It was also in the seq scan with a count of 6, but the
way the comparison works is that it sorts each representation of the table by
the key column value and then stops at the first difference, in this case count
columns 1 == 6 failed the assertion.

If you get some all-NULL rows, then you will also get Perl warnings issued when
the RETURNING clause starts returning NULL when none are expected to be.

The overall pattern seems to be pretty streaky.  It could go 20 iterations with
no problem, and then it will fail several times in a row.  I've seen this
pattern quite a bit with other race conditions as well, I think that they may
be sensitive to how memory gets laid out between CPUs, and that might depend on
some longer-term characteristic of the state of the machine that survives an
initdb.

By the way, I also got a new error message a few times that I think might be a
manifestation of the same thing:

```
ERROR:  duplicate key value violates unique constraint "foo_index_idx"
DETAIL:  Key (index)=(6106) already exists.
STATEMENT:  insert into foo (index, count) values ($2,$1) on conflict
(index)
                      update set count=TARGET.count + EXCLUDED.count
returning foo.count
```

Exclusion Constraints
---------------------
The need to test Value locking approach #2's implementation with exclusion
constraints is important.  It's only used by INSERT with ON CONFLICT IGNORE,
because the support only makes sense for that feature.  However, in principle
exclusion constraints and unique indexes (B-Trees) should have equivalent value
locking.

We want to take advantage of this test suite for testing exclusion constraints,
though, since in general it has proven effective.  If we assume that exclusion
constraints are not used as a generalization of unique constraints, but rather
are used only as an independent implementation of unique constraints, we can
stress test that independent implementation, too.  INSERT ... ON CONFLICT
UPDATE as used by the test suite has a lot more checks and balances than an
IGNORE-based stress test could (e.g. we can be sure that the right tuple is
updated by adding `WHERE EXCLUDED.index = TARGET.index ... RETURNING ... `, and
checking that tuples are projected in the perl script).

First, patch up the Value locking #2 patch, so parse analysis does not require
that an inference specification is provided for the UPDATE variant, like this:

```
diff --git a/src/backend/parser/parse_clause.c b/src/backend/parser/parse_clause.c
index e7c16fb..abd7741 100644
--- a/src/backend/parser/parse_clause.c
+++ b/src/backend/parser/parse_clause.c
@@ -2288,12 +2288,14 @@ transformConflictClause(ParseState *pstate, ConflictClause *confClause,
 {
        InferClause        *infer = confClause->infer;

+#if 0
        if (confClause->specclause == SPEC_INSERT && !infer)
                ereport(ERROR,
                                (errcode(ERRCODE_SYNTAX_ERROR),
                                 errmsg("ON CONFLICT with UPDATE must contain columns or expressi
                                 parser_errposition(pstate,
                                                                        exprLocation((Node *) con
+#endif

        /* Raw grammar must ensure this invariant holds */
        Assert(confClause->specclause != SPEC_INSERT ||
```

Build and install Postgres.  Make sure to build and install contrib/btree_gist,
too.  This is used to make exclusion constraints implemented with GiST indexes
that behave identically to unique constraints.

It should now be possible to use the script "count_upsert_exclusion.pl" to
stress test the implementation equivalently.
