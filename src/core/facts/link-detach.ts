/**
 * `gbrain facts link` detach (#explicit link): take a fact off the page fence
 * that currently owns it, without expiring it or recording a withdrawal, so
 * the following explicit link can publish it onto the operator's page.
 *
 * The fact's fence columns are cleared before the page projection runs. The
 * projection expires a fence row that disappeared while `row_num` is still
 * set; clearing first leaves the row database-only and active.
 */

import type { BrainEngine } from '../engine.ts';
import type { GBrainConfig } from '../config.ts';
import { opError } from '../ops/contract.ts';
import { serializePageToMarkdown } from '../markdown.ts';
import { FACTS_FENCE_BEGIN, FACTS_FENCE_END, parseFactsFence, renderFactsTable } from '../facts-fence.ts';
import type { PreparedMutation } from '../persistence/coordinator.ts';
import type { WriteRequest } from '../persistence/model.ts';
import { applyPreservingTakeResolutions, readFacts } from '../persistence/prepared-maintenance.ts';
import { appendContextNote } from './subject-infer.ts';
import { admitFactPageIntent, relinkFactHash, type RelinkGroupResult } from './relink-publish.ts';

export const DETACH_OPERATION = 'detach_fact';

export interface DetachIntentFact { id: number; hash: string; row_num: number; note: string }
export interface DetachIntent { kind: 'detach_fact'; run_id: string; facts: DetachIntentFact[] }
export interface DetachOutcome {
  detached: number[];
  skipped: Array<{ id: number; reason: 'revision_conflict' }>;
}

type Classified =
  | { id: number; action: 'detach'; value: Record<string, unknown>; rowNum: number }
  | { id: number; action: 'skip'; reason: 'revision_conflict' };

function withoutRows(body: string, rowNums: Set<number>): string {
  const parsed = parseFactsFence(body);
  if (parsed.warnings.length) {
    throw opError('invalid_params', 'fence_malformed: the facts fence is malformed; repair it before moving a fact.',
      'Fix the ## Facts table (one header row, then one row per fact), then rerun gbrain facts link; nothing was written.');
  }
  const begin = body.indexOf(FACTS_FENCE_BEGIN);
  const end = body.indexOf(FACTS_FENCE_END, begin + 1);
  if (begin < 0 || end < 0 || !parsed.facts.some(f => rowNums.has(f.rowNum))) {
    throw opError('revision_conflict', 'fence_drift: the fence row is not on that page.',
      'The fact records a fence row the page body does not have. Repair the fence, then rerun gbrain facts link; nothing was written.');
  }
  const next = renderFactsTable(parsed.facts.filter(f => !rowNums.has(f.rowNum)));
  return body.slice(0, begin) + next + body.slice(end + FACTS_FENCE_END.length);
}

async function classify(db: BrainEngine, row: WriteRequest, intent: DetachIntent, present: Set<number>, lock: boolean): Promise<Classified[]> {
  const current = await readFacts(db, row.source_id, intent.facts.map(f => f.id), lock);
  const out: Classified[] = [];
  for (const f of intent.facts) {
    const snap = current.find(c => c.id === f.id);
    const v = snap?.value;
    const owned = v !== undefined && v.expired_at === null && Number(v.row_num) === f.row_num && v.source_markdown_slug === row.slug && present.has(f.row_num);
    if (!snap || relinkFactHash(snap) !== f.hash || !owned) out.push({ id: f.id, action: 'skip', reason: 'revision_conflict' });
    else out.push({ id: f.id, action: 'detach', value: v, rowNum: f.row_num });
  }
  return out;
}

const classKey = (c: Classified[]) => JSON.stringify(c.map(x => x.action === 'detach' ? [x.id, x.rowNum] : [x.id, 'skip']));

export async function prepareDetachMutation(engine: BrainEngine, row: WriteRequest, config: GBrainConfig): Promise<PreparedMutation> {
  const intent = row.intent as unknown as DetachIntent | null;
  const rerun = `Rerun gbrain facts link --source ${row.source_id}; preview it with --dry-run (no writes).`;
  const changed = (message: string) => opError('revision_conflict', message,
    `${row.slug} or one of its facts changed while detach request ${row.request_id} was being prepared, so nothing was written. ${rerun}`);
  if (row.operation !== DETACH_OPERATION || intent?.kind !== 'detach_fact' || !Array.isArray(intent.facts) || row.authority.remote) {
    throw opError('permission_denied', 'Unsupported fact detach.',
      `Request ${row.request_id} is not a trusted local fact move this gbrain version can publish, so nothing was written. Moving a fact runs only from gbrain facts link on the brain host.`);
  }
  const snapshot = await engine.readPageSnapshot(row.slug, { sourceId: row.source_id });
  if (!snapshot || snapshot.page.id !== row.page_id) {
    throw opError('page_identity_changed', 'The fact\'s current page changed.',
      `${row.slug} in ${row.source_id} was deleted or replaced after detach request ${row.request_id} was accepted, so nothing was written. ${rerun}`);
  }
  const parsed = parseFactsFence(snapshot.page.compiled_truth);
  if (parsed.warnings.length) {
    throw opError('invalid_params', 'fence_malformed: the facts fence is malformed; repair it before moving a fact.',
      `Fix the ## Facts table on ${row.slug} in ${row.source_id}, then rerun gbrain facts link; nothing was written.`);
  }
  const present = new Set(parsed.facts.map(f => f.rowNum));
  const observedRevision = snapshot.revision;
  const planned = await classify(engine, row, intent, present, false);
  const byId = new Map(intent.facts.map(f => [f.id, f]));
  const detaches = planned.filter((c): c is Extract<Classified, { action: 'detach' }> => c.action === 'detach');
  let body = snapshot.page.compiled_truth;
  if (detaches.length) body = withoutRows(body, new Set(detaches.map(d => d.rowNum)));
  const page = detaches.length ? await (await import('../persistence/page-prepare.ts')).preparePageMutation(engine, { ...row, intent: {
    content: serializePageToMarkdown({ ...snapshot.page, compiled_truth: body }, snapshot.tags), expected_revision: observedRevision, force: false,
  } }, config) : undefined;
  if (page && page.observedRevision !== observedRevision) throw changed('The fact\'s current page changed during preparation.');
  const validate = async (tx: BrainEngine) => {
    if (classKey(await classify(tx, row, intent, present, true)) !== classKey(planned)) throw changed('A fact changed during preparation.');
    await page?.validate?.(tx);
  };
  const apply = async (tx: BrainEngine): Promise<Record<string, unknown>> => {
    const outcome: DetachOutcome = { detached: [], skipped: [] };
    for (const c of planned) {
      if (c.action === 'skip') { outcome.skipped.push({ id: c.id, reason: c.reason }); continue; }
      const f = byId.get(c.id)!;
      const cleared = await tx.executeRaw(
        `UPDATE facts SET row_num=NULL, source_markdown_slug=NULL, context=$4
          WHERE source_id=$1 AND id=$2 AND row_num=$3::integer AND source_markdown_slug=$5 AND expired_at IS NULL RETURNING id`,
        [row.source_id, c.id, c.rowNum, appendContextNote(c.value.context as string | null, f.note), row.slug]);
      if (cleared.length !== 1) throw changed('A fact was moved by another writer.');
      outcome.detached.push(c.id);
    }
    const published = page ? await applyPreservingTakeResolutions(tx, row.page_id, page) : {};
    return { ...published, status: 'detached', slug: row.slug, ...outcome };
  };
  if (!page) return { observedRevision, validate, apply };
  return { ...page, validate, apply };
}

export async function submitDetachGroup(engine: BrainEngine, config: GBrainConfig, sourceId: string, slug: string,
  intent: DetachIntent): Promise<{ ok: true; outcome: DetachOutcome } | Extract<RelinkGroupResult, { ok: false }>> {
  const result = await admitFactPageIntent(engine, config, sourceId, slug, DETACH_OPERATION,
    intent as unknown as Record<string, unknown>,
    { operation: DETACH_OPERATION, sourceId, slug, run: intent.run_id, facts: intent.facts.map(f => [f.id, f.hash, f.row_num]) });
  if (!result.ok) return result;
  return { ok: true, outcome: result.outcome as unknown as DetachOutcome };
}
