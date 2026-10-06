# Retrieval eval stub (20 asks)

Skeleton for `gbrain eval retrieval-quality`. The queries are placeholders.
`relevant` arrays are empty on purpose. An empty list is not a score: hit
rate stays zero until someone fills slugs from the live wiki.

Do not run this against the live brain from CI or a cloud agent. On the box,
after the slugs are filled:

```bash
gbrain eval retrieval-quality ops/yh-brain-box/evals/queries.jsonl --source default --json
```

`queries.jsonl` is the file that command reads (`family`, `query`, `relevant`,
and `forbidden` for hard-negative). `qrels.stub.json` is the same 20 asks in
a qrels-shaped document with empty `relevant_slugs`, for people who keep
grades in that form. Fill both from the same slugs.

## How to fill

1. On the box, search the wiki for each question and pick the page that should
   rank. Use placeholder-style slugs already in the brain (`crm/client-...`,
   project hubs). Do not paste private names into this public repo; keep the
   filled file on the box if the slugs are sensitive.
2. Set `relevant` to those slugs. For the two hard-negative asks, set
   `forbidden` to slugs that must not appear and leave `relevant` empty.
3. Mirror the same slugs into `qrels.stub.json` (`relevant_slugs`,
   `first_relevant_slug`) and change `"status"` from `stub` when the list is
   real.
4. Run the command above. The harness gates families that have questions.
   Empty relevant lists fail a real gate. That is expected until step 2.

`stub: true` on each line marks the fixture as unfinished.
