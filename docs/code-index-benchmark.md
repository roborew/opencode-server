# code-index token benchmark

Status: **not run yet.** It needs the live server with code-index deployed. This
page records the protocol now so the numbers are comparable when they are taken.
The success bar (opencode-config-v2 spec, SC 6) is **≥ 40% fewer tokens with no
loss in answer quality**; a shortfall is reported as measured, with a
recommendation.

## Protocol

1. Pick one real app repo on the server (more than 1k files). Index it once
   (`code-index_index_repository`) before the "enabled" runs.
2. Use the same model and agent (`build`), a fresh session per question, and no
   other MCP traffic.
3. Ask each question below twice: once with code-index disabled
   (`"enabled": false` for `code-index` in the server override, then recreate
   `opencode`), and once enabled.
4. Record from the session's usage: input + output tokens and the number of tool
   calls. Grade each answer as correct, partial or wrong against the code.
5. SC 5b (natural-language lookup): for N1–N5, the right symbol must appear in the
   top 5 `search_graph` results with `query` for at least 4 of 5.

## Questions

Fill in the concrete wording for the chosen repo before the first run, and keep it
fixed afterwards.

| ID | Kind | Question |
|---|---|---|
| S1 | structural | Who calls `<function>`? |
| S2 | structural | What does `<entry point>` call, down to the database layer? |
| S3 | structural | Which modules depend on `<module>`? |
| S4 | structural | Where is `<interface>` implemented? |
| S5 | structural | What is the call path from `<handler>` to `<side effect>`? |
| N1 | natural language | Where is retry or backoff handled? |
| N2 | natural language | How is configuration loaded at startup? |
| N3 | natural language | Where are permissions or auth checked? |
| N4 | natural language | Where are background jobs scheduled? |
| N5 | natural language | Where is the cache key built? |

## Results

Repo: — · Model: — · Date: —

| ID | Tokens (off) | Tokens (on) | Δ | Tool calls (off → on) | Quality (off / on) |
|---|---|---|---|---|---|
| S1–S5, N1–N5 | | | | | |
| **Total** | | | | | |

SC 5b top-5 hits: — / 5

## Conclusion

To be written after the run.
