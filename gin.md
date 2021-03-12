# YSQL GIN indexes

## Terms

- indexed table: indexes are on _indexed tables_

## Background

```sql
CREATE TABLE book (page int PRIMARY KEY, word text, position int);
```

creates a DocDB table with key `page HASH`.  I can easily ask for pages 5-12
using this primary key:

```sql
SELECT * FROM book WHERE page >= 5 and page <= 12;
```

```sql
CREATE INDEX ON book (word);
```

creates a secondary DocDB table with key `word HASH, page ASC`.  This is like
the index at the back of a book.  I can easily ask what pages have the word
`foo` using this index:

```sql
SELECT page FROM book WHERE word = 'foo';
```

What if the table were structured instead like

```sql
CREATE TABLE book (page int PRIMARY KEY, words text[]);
```

Now, looking for the specific word `foo` is time-consuming:

```sql
select * from book where '{foo}' && words;
```

Creating a regular index won't help since you still need to search `words` for
`foo`.

## Overview

GIN indexes map values _inside a column_ rather than the whole column.

```sql
CREATE INDEX ON book USING gin (words);
```

should create a secondary DocDB table with key `word HASH, pages ASC`, where
`word` is a word in `words`.  If I insert a page with 300 unique words and 500
total words, I add 300 records to the index, all referencing the same page.

## Limitations

- GIN indexes can only be used on column types `tsvector`, `anyarray`, `jsonb`
- GIN indexes cannot be unique
- GIN indexes can be on more than one column, but all columns must be GINable

## GIN opclasses

Indexes have an access method (e.g. btree, lsm, gin) and an opclass.  **The
opclass determines the index key format!**  Here are the opclasses that can be
used with GIN ([source][pg-gin-opclasses]):

| opclass          | type       | supported operators
| ---------------- | ---------- | ---------------------------------
| `tsvector_ops`   | `tsvector` | `@@`, `@@@`
| `array_ops`      | `anyarray` | `&&`, `<@`, `=`, `@>`
| `jsonb_ops`      | `jsonb`    | `?`, `?&`, `?|`, `@>`, `@?`, `@@`
| `jsonb_path_ops` | `jsonb`    | `@>`, `@?`, `@@`

If I `CREATE INDEX ON bar USING gin (jsonb_col)`, I implicitly use opclass
`jsonb_ops`.  To use `jsonb_path_ops`, I need to `CREATE INDEX ON bar USING gin
(jsonb_col jsonb_path_ops)`.

[pg-gin-opclasses]: https://www.postgresql.org/docs/current/gin-builtin-opclasses.html

## Operators

All the operators boil down to a combination of these primitives:

- set `a` contains element `b`?  (`@>`)
  - contains element greater than
  - contains element greater than or equal to
  - contains element less than
  - contains element less than or equal to
  - contains element with prefix
- logical and, not, or
- recheck

Recheck is the fallback we can rely on for complicated queries.

I represent each operator using these primitives:

- `tsvector @@ tsquery → boolean`: (custom)
  - tsquery `a | b`: (set `LHS` contains element `a`) OR (set `LHS` contains
    element `b`)
  - tsquery `a & b`: (set `LHS` contains element `a`) AND (set `LHS` contains
    element `b`)
  - tsquery `!a`: NOT(set `LHS` contains element `a`)
  - tsquery `a:*'`: (set `LHS` contains element **with prefix** `a`)
- `anyarray && anyarray → boolean`: OR(set `LHS` contains element `RHS[*]`)
- `anyarray <@ anyarray → boolean`: OR(set `LHS` contains element `RHS[*]`) +
  recheck
- `anyarray = anyarray → boolean`: AND(set `LHS` contains element `RHS[*]`) +
  recheck
- `anyarray @> anyarray → boolean`: AND(set `LHS` contains element `RHS[*]`)
- `jsonb ? text → boolean`: set `LHS` contains element `RHS`
- `jsonb ?& text[] → boolean`: AND(set `LHS` contains element `RHS[*]`)
- `jsonb ?| text[] → boolean`: OR(set `LHS` contains element `RHS[*]`)
- `jsonb @> jsonb → boolean`: AND(set `LHS` contains element `RHS[*]`)
- `jsonb @? jsonpath → boolean`: (custom)
- `jsonb @@ jsonpath → boolean`: (custom)
  - jsonpath `$.a == 7`: set `LHS` contains element `<key>a.<num>7`
  - jsonpath `$.a > 7`: (set `LHS` contains element **greater than**
    `<key>a.<num>7`) AND (set `LHS` contains element **with prefix**
    `<key>a.<num>`)
  - jsonpath `$.a != 7`: (set `LHS` contains element **with prefix**
    `<key>a.<num>`) AND NOT(set `LHS` contains element `<key>a.<num>7`)
  - jsonpath `($.a == 7) && ! ($.b == 8)`: (set `LHS` contains element
    `<key>a.<num>7`) AND NOT(set `LHS` contains element `<key>b.<num>8`)
  - jsonpath `$.a like_regex "^foo.*bar"`: set `LHS` contains element **with
    prefix** `<key>a.<str>` + recheck
  - jsonpath `$.a starts with "bar"`: set `LHS` contains element **with
    prefix** `<key>a.<str>bar`
  - jsonpath `$.a.ceiling() == 5`: set `LHS` contains element `<key>a.<num>` +
    recheck
  - jsonpath `$.a.type() == "number"`: set `LHS` contains element **with
    prefix** `<key>a.<num>`
  - jsonpath `$.a + ($.b % $.c) == 7`: (set `LHS` contains element **with
    prefix** `<key>a.<num>`) AND (set `LHS` contains element **with prefix**
    `<key>b.<num>`) AND (set `LHS` contains element **with prefix**
    `<key>c.<num>`) + recheck

- [tsvector operators][tsvector-ops]
- [anyarray operators][anyarray-ops]
- [jsonb operators][jsonb-ops]

[tsvector-ops]: https://www.postgresql.org/docs/current/functions-textsearch.html
[anyarray-ops]: https://www.postgresql.org/docs/current/functions-array.html
[jsonb-ops]: https://www.postgresql.org/docs/current/functions-json.html

#### DocDB

DocDB can probably encode these like

1. `[many, 3]`
1. `[many, 4]`
1. `[slitter, 3]`

assuming the primary keys of the indexed table are ints like `3` and `4`.
Prefix searches can be done like `[slit`, but the text should be carefully
encoded so that `t` is the last part of the search, not something like `!`
(`kGroupEnd`).  TODO: look into DocDB encoding for `kString`.

TODO: look into `tsvector` **weights**

#### DocDB

DocDB can probably encode these like

1. `[<JSON>, a, 1, 1]`
1. `[<JSON>, b, <JSON>, c, d, 2]`
1. `[<JSON>, b, <JSON>, c, e, 3]`
1. `[<JSON>, b, <ARRAY>, 1, 4]`
1. `[<JSON>, b, <ARRAY>, <ARRAY>, 2, 4]`
1. `[<JSON>, b, <ARRAY>, <ARRAY>, 3, 4]`
1. `[<JSON>, b, <ARRAY>, 4, 4]`
1. `[<JSON>, c, f, 4]`

(This is inspired by [CockroachDB's inverted index RFC][crdb-rfc].)

Contains (`@>`) searches can be like

- `j @> '{"a": 1}'` = `[<JSON>, a, 1`
- `j @> '{"b": {}}'` = `[<JSON>, b, <JSON>`
- `j @> '{"b": []}'` = `[<JSON>, b, <ARR>`
- `j @> '{"b": [[]]}'` = `[<JSON>, b, <ARR>, <ARR>`
- `j @> '{"b": [4]}'` = `[<JSON>, b, <ARR>, 4`

Concerns

- `25.0` and `25` match should equally match--what will the number format be
  like?
- What will the text encoding be like, especially for weird unicode, and how
  does prefix matching work, then?
- How will the end of the JSON document be marked?  (Same question for marking
  array end on array GIN index.)  `kGroupEnd`?  But doesn't this mean the
  contents of the JSON GIN key have to be encoded in some way to make
  exclamation marks unambiguous?

[crdb-rfc]: https://github.com/cockroachdb/cockroach/blob/master/docs/RFCS/20171020_inverted_indexes.md

## Postgres changes

- To avoid bitmap scan logic, redirection must happen from high up at
  `ExecInitBitmapIndexScan`
- `TS_execute` is deep in the stack, and it interprets tsquery operators.  This
  suggests that work needs to be done to either
  - push down tsvector/tsquery `@@` operator to DocDB
  - interpret tsqueries at a high level and split into multiple simple scans

# Appendix

## DocDB for normal index

Here is a step-by-step guide to see how normal indexes are represented in
DocDB.

```sh
./bin/yb-ctl create \
  --master_flags "ysql_disable_index_backfill=true" \
  --tserver_flags "TEST_docdb_log_write_batches=true,ysql_disable_index_backfill=true,ysql_num_shards_per_tserver=1"
tail -F ~/yugabyte-data/node-1/disk-1/yb-data/tserver/logs/yb-tserver.INFO
```

```sql
CREATE TABLE t (p bool PRIMARY KEY, c char, i int);
INSERT INTO t VALUES (true, 'b', 2);
INSERT INTO t VALUES (false, null, null);
```

```sql
CREATE INDEX ON t (c);
```

Observe logs for _regular_ DocDB writes

```
I0216 18:08:50.375550 31976 tablet.cc:1235] T dfc95b4d53b44afebc4827b29bcc6769 P 5fb87e8c88ea477ab7ebb4b9a3bb4bdc: Wrote 2 key/value pairs to kRegular RocksDB:
Frontiers: { smallest: { op_id: 1.3 hybrid_time: { physical: 1613527730374840 } history_cutoff: <invalid> hybrid_time_filter: <invalid> } largest: { op_id: 1.3 hybrid_time: { physical: 1613527730374840 } history_cutoff: <invalid> hybrid_time_filter: <invalid> } }
1. PutCF(SubDocKey(DocKey(0xebd4, ["b"], ["G\x8f\xf7T!!"]), [SystemColumnId(0); HT{ physical: 1613527730370761 }]), '#\x80\x01\x98\xbfC\xf5\xd5\xab\x80J$' (23800198BF43F5D5AB804A24))
2. PutCF(SubDocKey(DocKey(0x4d44, [null], ["G\xdc@F!!"]), [SystemColumnId(0); HT{ physical: 1613527730370761 w: 1 }]), '#\x80\x01\x98\xbfC\xf5\xd5\xab\x80?\xab$' (23800198BF43F5D5AB803FAB24))
```

In simpler terms,

1. `["b", true]`
2. `[null, false]`

`IndexScan` on `c = 'b'` can look in this index for `["b"]` prefix, get the
next key component `true`, then look up `true` in the indexed table.

```sql
CREATE UNIQUE INDEX ON t (i);
```

Observe logs for _regular_ DocDB writes

```
I0216 18:10:06.280701 31753 tablet.cc:1235] T bb21a24b24eb421b8b7a84fb03422271 P 5fb87e8c88ea477ab7ebb4b9a3bb4bdc: Wrote 4 key/value pairs to kRegular RocksDB:
Frontiers: { smallest: { op_id: 1.3 hybrid_time: { physical: 1613527806280035 } history_cutoff: <invalid> hybrid_time_filter: <invalid> } largest: { op_id: 1.3 hybrid_time: { physical: 1613527806280035 } history_cutoff: <invalid> hybrid_time_filter: <invalid> } }
1. PutCF(SubDocKey(DocKey(0xc0c4, [2], [null]), [SystemColumnId(0); HT{ physical: 1613527806278239 }]), '#\x80\x01\x98\xbf?o\x8e\x93\x80J$' (23800198BF3F6F8E93804A24))
2. PutCF(SubDocKey(DocKey(0xc0c4, [2], [null]), [ColumnId(12); HT{ physical: 1613527806278239 w: 1 }]), '#\x80\x01\x98\xbf?o\x8e\x93\x80?\xabSG\x8f\xf7T!!' (23800198BF3F6F8E93803FAB53478FF7542121))
3. PutCF(SubDocKey(DocKey(0x4d44, [null], ["G\xdc@F!!"]), [SystemColumnId(0); HT{ physical: 1613527806278239 w: 2 }]), '#\x80\x01\x98\xbf?o\x8e\x93\x80?\x8b$' (23800198BF3F6F8E93803F8B24))
4. PutCF(SubDocKey(DocKey(0x4d44, [null], ["G\xdc@F!!"]), [ColumnId(12); HT{ physical: 1613527806278239 w: 3 }]), '#\x80\x01\x98\xbf?o\x8e\x93\x80?kSG\xdc@F!!' (23800198BF3F6F8E93803F6B5347DC40462121))
```

In simpler terms,

1. `[2, null]` -> `true`
2. `[null, false]` -> `false`

`IndexScan` on `i = 2` can look in this index for `[2]` prefix, get the value
`true`, then look up `true` in the indexed table.

## Example: tsvector

Here is an example of using a tsvector GIN index.  It is inspired by a [habr
blog][habr-blog].  Run on upstream postgres.

```sql
CREATE TABLE docs (
    doc text,
    ts tsvector GENERATED ALWAYS AS (to_tsvector('simple', doc)) STORED);
INSERT INTO docs (doc) VALUES
  ('Can a sheet slitter slit sheets?'),
  ('How many sheets could a sheet slitter slit?'),
  ('I slit a sheet, a sheet I slit.'),
  ('Upon a slitted sheet I sit.'),
  ('Whoever slit the sheets is a good sheet slitter.'),
  ('I am a sheet slitter.'),
  ('I slit sheets.'),
  ('I am the sleekest sheet slitter that ever slit sheets.'),
  ('She slits the sheet she sits on.');
SELECT * FROM docs; -- what tsvector looks like
```

```sql
CREATE INDEX ON docs USING GIN (ts);
SET enable_seqscan = OFF;
EXPLAIN SELECT * FROM docs
    WHERE ts @@ to_tsquery('simple', 'many'); -- this is index scan
```

Example of what can be done, all using the index:

```sql
SELECT doc FROM docs WHERE ts @@ to_tsquery('simple', 'many & slitter');
SELECT doc FROM docs WHERE ts @@ to_tsquery('simple', 'many | slitter');
SELECT doc FROM docs WHERE ts @@ to_tsquery('simple', 'slit:* & !slit');
SELECT ts_rank(ts, to_tsquery('simple', 'i & sheet:* & slit:*')) as rank, doc
    FROM docs
    WHERE ts @@ to_tsquery('simple', 'i & sheet:* & slit:*')
    ORDER BY rank DESC;
```

[habr-blog]: https://habr.com/en/company/postgrespro/blog/448746/

## Example: jsonb

Here is an example of using a jsonb GIN index.

```sql
CREATE TABLE records (p SERIAL PRIMARY KEY, j jsonb);
INSERT INTO records (j) VALUES
  ('{"a": 1}'),
  ('{"b": {"c": "d"}}'),
  ('{"b": {"c": "e"}}'),
  ('{"b": [1, [2, 3], 4], "c": "f"}');
CREATE INDEX ON records USING GIN (j jsonb_ops);
SET enable_seqscan = OFF;
EXPLAIN SELECT * FROM records WHERE j @> '{"b": {}}'; -- this is index scan
```

Example of what can be done, all using the index:

```sql
SELECT * FROM records WHERE j @> '{"b": {}}';
SELECT * FROM records WHERE j ? 'c';
SELECT * FROM records WHERE j ?| ARRAY['a', 'c'];
SELECT * FROM records WHERE j ?& ARRAY['c', 'b'];
SELECT * FROM records WHERE j @? '$.b[*] ? (@ > 3)';
SELECT * FROM records WHERE j @@ '$.b.c == "e"';
```

You can think of

```sql
SELECT * FROM records WHERE j @? '$.b[*] ? (@ == 3)';
```

to be like

```sql
SELECT * FROM records WHERE (
    j @@ '$.b[0] == 3' or
    j @@ '$.b[1] == 3' or
    j @@ '$.b[2] == 3');
```

# Advanced material

These are some more involved details that can be helpful to developers.

## Execution trees

### Read

    exec_simple_query
      PortalStart
        ExecutorStart
          standard_ExecutorStart
            InitPlan
              ExecInitNode
                ExecInitBitmapHeapScan
                  ExecInitNode
                    ExecInitBitmapIndexScan
                      index_beginscan_bitmap
                        index_beginscan_internal
                          ambeginscan
      PortalRun
        PortalRunSelect
          ExecutorRun
            standard_ExecutorRun
              ExecutePlan
                ... ExecBitmapHeapScan
                  ExecScanFetch
                    BitmapHeapNext
                      MultiExecProcNode
                        MultiExecBitmapIndexScan
                          index_getbitmap
                            gingetbitmap
                        MultiExecBitmapAnd
                        MultiExecBitmapOr

Entry point for using text search functions:

    (gdb) bt
    #0  TS_execute (curitem=0x1749d90, arg=arg@entry=0x7ffdf8c8ea50, flags=flags@entry=2, chkcond=chkcond@entry=0x842ad0 <checkcondition_gin>) at tsvector_op.c:1848
    #1  0x00000000008430c3 in gin_tsquery_triconsistent (fcinfo=<optimized out>) at tsginidx.c:287
    #2  0x0000000000881fdd in FunctionCall7Coll (flinfo=0x17ffe98, collation=<optimized out>, arg1=<optimized out>, arg2=<optimized out>, arg3=<optimized out>, arg4=<optimized out>, arg5=25151648, arg6=25151592, arg7=25151768) at fmgr.c:1311
    #3  0x000000000049dc10 in directTriConsistentFn (key=<optimized out>) at ginlogic.c:97
    #4  0x000000000049c39f in startScanKey (ginstate=0x17fe580, so=0x17fe578, so=0x17fe578, key=0x17fc648) at ginget.c:566
    #5  startScan (scan=0x17e73f0, scan=0x17e73f0) at ginget.c:642
    #6  gingetbitmap (scan=0x17e73f0, tbm=0x18053d8) at ginget.c:1951
    #7  0x00000000004d3d9a in index_getbitmap (scan=scan@entry=0x17e73f0, bitmap=bitmap@entry=0x18053d8) at indexam.c:671
    #8  0x0000000000632882 in MultiExecBitmapIndexScan (node=0x17e7100) at nodeBitmapIndexscan.c:105
    #9  0x00000000006220e1 in MultiExecProcNode (node=<optimized out>) at execProcnode.c:510
    #10 0x0000000000631f50 in BitmapHeapNext (node=node@entry=0x17e6e10) at nodeBitmapHeapscan.c:113
    #11 0x00000000006245fa in ExecScanFetch (recheckMtd=0x6321c0 <BitmapHeapRecheck>, accessMtd=0x631820 <BitmapHeapNext>, node=0x17e6e10) at execScan.c:133
    #12 ExecScan (node=0x17e6e10, accessMtd=0x631820 <BitmapHeapNext>, recheckMtd=0x6321c0 <BitmapHeapRecheck>) at execScan.c:199
    #13 0x000000000061af52 in ExecProcNode (node=0x17e6e10) at ../../../src/include/executor/executor.h:248
    #14 ExecutePlan (execute_once=<optimized out>, dest=0x17f5ba8, direction=<optimized out>, numberTuples=0, sendTuples=true, operation=CMD_SELECT, use_parallel_mode=<optimized out>, planstate=0x17e6e10, estate=0x17e6be8) at execMain.c:1646
    #15 standard_ExecutorRun (queryDesc=0x17f9738, direction=<optimized out>, count=0, execute_once=<optimized out>) at execMain.c:364
    #16 0x0000000000770afb in PortalRunSelect (portal=portal@entry=0x178b008, forward=forward@entry=true, count=0, count@entry=9223372036854775807, dest=dest@entry=0x17f5ba8) at pquery.c:912
    #17 0x0000000000771d68 in PortalRun (portal=portal@entry=0x178b008, count=count@entry=9223372036854775807, isTopLevel=isTopLevel@entry=true, run_once=run_once@entry=true, dest=dest@entry=0x17f5ba8, altdest=altdest@entry=0x17f5ba8, qc=qc@entry=0x7ffdf8c8
    efe0) at pquery.c:756
    #18 0x000000000076dabe in exec_simple_query (query_string=0x1724c68 "SELECT doc FROM docs WHERE ts @@ to_tsquery('simple', 'many & slitter');") at postgres.c:1239
    #19 0x000000000076ee37 in PostgresMain (argc=<optimized out>, argv=argv@entry=0x174f0b8, dbname=0x174f000 "testupdatejoin", username=<optimized out>) at postgres.c:4315
    #20 0x0000000000481e23 in BackendRun (port=<optimized out>, port=<optimized out>) at postmaster.c:4536
    #21 BackendStartup (port=0x1748270) at postmaster.c:4220
    #22 ServerLoop () at postmaster.c:1739
    #23 0x00000000006fc793 in PostmasterMain (argc=argc@entry=3, argv=argv@entry=0x171f980) at postmaster.c:1412
    #24 0x0000000000482a6e in main (argc=3, argv=0x171f980) at main.c:210

## Constants

    #define JsonbContainsStrategyNumber   7
    #define JsonbExistsStrategyNumber   9
    #define JsonbExistsAnyStrategyNumber  10
    #define JsonbExistsAllStrategyNumber  11
    #define JsonbJsonpathExistsStrategyNumber   15
    #define JsonbJsonpathPredicateStrategyNumber  16

## Misc

- At `ginbeginscan`,

      (gdb) p so->ginstate
      $32 = {
        index = 0x7fbef38c56f0,
        oneCol = true,
        origTupdesc = 0x7fbef38c5a10,
        tupdesc = {0x7fbef38c5a10, 0x0 <repeats 31 times>},
        compareFn = {{
            fn_addr = 0x842b30 <gin_cmp_tslexeme>,
            fn_oid = 3724,
            fn_nargs = 2,
            fn_strict = true,
            fn_retset = false,
            fn_stats = 2 '\002',
            fn_extra = 0x0,
            fn_mcxt = 0x17e5760,
            fn_expr = 0x17ee788
          }, {
            fn_addr = 0x0,
            fn_oid = 0,
            fn_nargs = 0,
            fn_strict = false,
            fn_retset = false,
            fn_stats = 0 '\000',
            fn_extra = 0x0,
            fn_mcxt = 0x0,
            fn_expr = 0x0
          } <repeats 31 times>},
        extractValueFn = {{
            fn_addr = 0x842d90 <gin_extract_tsvector>,
            fn_oid = 3656,
            fn_nargs = 3,
            fn_strict = true,
            fn_retset = false,
            fn_stats = 2 '\002',
            fn_extra = 0x0,
            fn_mcxt = 0x17e5760,
            fn_expr = 0x17eea70
          }, {
            fn_addr = 0x0,
            fn_oid = 0,
            fn_nargs = 0,
            fn_strict = false,
            fn_retset = false,
            fn_stats = 0 '\000',
            fn_extra = 0x0,
            fn_mcxt = 0x0,
            fn_expr = 0x0
          } <repeats 31 times>},
        extractQueryFn = {{
            fn_addr = 0x842e30 <gin_extract_tsquery>,
            fn_oid = 3657,
            fn_nargs = 7,
            fn_strict = true,
            fn_retset = false,
            fn_stats = 2 '\002',
            fn_extra = 0x0,
            fn_mcxt = 0x17e5760,
            fn_expr = 0x17eeac0
          }, {
            fn_addr = 0x0,
            fn_oid = 0,
            fn_nargs = 0,
            fn_strict = false,
            fn_retset = false,
            fn_stats = 0 '\000',
            fn_extra = 0x0,
            fn_mcxt = 0x0,
            fn_expr = 0x0
          } <repeats 31 times>},
        consistentFn = {{
            fn_addr = 0x843000 <gin_tsquery_consistent>,
            fn_oid = 3658,
            fn_nargs = 8,
            fn_strict = true,
            fn_retset = false,
            fn_stats = 2 '\002',
            fn_extra = 0x0,
            fn_mcxt = 0x17e5760,
            fn_expr = 0x17eeb60
          }, {
            fn_addr = 0x0,
            fn_oid = 0,
            fn_nargs = 0,
            fn_strict = false,
            fn_retset = false,
            fn_stats = 0 '\000',
            fn_extra = 0x0,
            fn_mcxt = 0x0,
            fn_expr = 0x0
          } <repeats 31 times>},
        triConsistentFn = {{
            fn_addr = 0x843070 <gin_tsquery_triconsistent>,
            fn_oid = 3921,
            fn_nargs = 7,
            fn_strict = true,
            fn_retset = false,
            fn_stats = 2 '\002',
            fn_extra = 0x0,
            fn_mcxt = 0x17e5760,
            fn_expr = 0x17eeb10
          }, {
            fn_addr = 0x0,
            fn_oid = 0,
            fn_nargs = 0,
            fn_strict = false,
            fn_retset = false,
            fn_stats = 0 '\000',
            fn_extra = 0x0,
            fn_mcxt = 0x0,
            fn_expr = 0x0
          } <repeats 31 times>},
        comparePartialFn = {{
            fn_addr = 0x842c50 <gin_cmp_prefix>,
            fn_oid = 2700,
            fn_nargs = 4,
            fn_strict = true,
            fn_retset = false,
            fn_stats = 2 '\002',
            fn_extra = 0x0,
            fn_mcxt = 0x17e5760,
            fn_expr = 0x17ff748
          }, {
            fn_addr = 0x0,
            fn_oid = 0,
            fn_nargs = 0,
            fn_strict = false,
            fn_retset = false,
            fn_stats = 0 '\000',
            fn_extra = 0x0,
            fn_mcxt = 0x0,
            fn_expr = 0x0
          } <repeats 31 times>},
        canPartialMatch = {true, false <repeats 31 times>},
        supportCollation = {100, 0 <repeats 31 times>}
      }
