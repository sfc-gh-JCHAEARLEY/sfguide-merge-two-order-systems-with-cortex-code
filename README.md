# The Merger: Two Order Systems, One Revenue Number with CoCo

Companion repo for the Snowflake guide **[The Merger: Two Order Systems, One Revenue Number with CoCo](https://www.snowflake.com/en/developers/guides/merge-two-order-systems-with-cortex-code/)**.

A coffee chain just bought a rival, and the two order systems disagree on everything. In the guide you use CoCo in Snowsight to reconcile them, build a Dynamic Table pipeline, fix it live when an upstream schema change breaks it, and build a Streamlit revenue dashboard.

## How to use this repo

Open it in Snowsight as a **Git-backed workspace** (Projects » Workspaces » Create new Git workspace) and follow the guide. You run the files in this order:

| File | When |
|------|------|
| `setup.sql` | Step 1. Creates `MERGER_ROLE`, `MERGER_WH`, `MERGER_DB`, and the source data. Run it as ACCOUNTADMIN. |
| `checks.sql` | After each step. Run the matching CHECK block; every row should say PASS. |
| `break_batch.sql` | Step 4. Renames a POS column, lands a new batch, and forces a refresh that fails on purpose. |

`solutions/` holds reference answers if you fall behind or want to compare against what CoCo built:

| File | Replaces |
|------|----------|
| `solutions/solution.sql` | The pipeline CoCo builds in step 3 |
| `solutions/fix_after_break.sql` | The fix CoCo makes in step 4 |
| `solutions/streamlit_app.py` | The dashboard CoCo writes in step 5 |

## Expected results

| Checkpoint | Orders | Total revenue |
|------------|--------|---------------|
| After the pipeline (CHECK 3) | 7,256 | $72,702.55 |
| After the break is fixed (CHECK 4) | 7,406 | $74,370.30 |

## Clean up

```sql
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS MERGER_DB;
DROP WAREHOUSE IF EXISTS MERGER_WH;
DROP ROLE IF EXISTS MERGER_ROLE;
```

## License

Apache 2.0. See [LICENSE](LICENSE).
