/**
 * `gbrain facts link`: set or override a fact's entity page from an operator
 * mapping. Publication is the same coordinator request as `gbrain facts relink`
 * (`relink_facts`, tier `explicit`), so the fact lands on that page's ## Facts
 * fence with its id, embedding and provenance kept. A fact that already lives
 * on a different page's fence is detached first (`detach_fact`) and then
 * linked. Neither step creates a page.
 */

import { randomUUID } from 'node:crypto';
import type { BrainEngine } from '../engine.ts';
import type { GBrainConfig } from '../config.ts';
import { validatePageSlug } from '../ops/context.ts';
import { parseFactsFence } from '../facts-fence.ts';
import { isFactWithdrawn } from './withdrawal.ts';
import { readFacts } from '../persistence/prepared-maintenance.ts';
import { relinkFactHash, submitRelinkGroup, type RelinkIntentFact } from './relink-publish.ts';
import { submitDetachGroup, type DetachIntentFact } from './link-detach.ts';

export const LINK_SCHEMA_VERSION = 1;
export const LINK_NOTE = 'entity linked by operator';

export interface LinkMapping { fact_id: number; slug: string }

export type LinkStatus = 'linked' | 'already_linked' | 'deduped' | 'skipped';
export interface LinkRowResult {
  fact_id: number;
  slug: string;
  status: LinkStatus;
  /** Set when a linked fact was taken off another page's fence first. */
  moved_from?: string;
  reason?: string;
}

export interface LinkReport {
  schema_version: number;
  dry_run: boolean;
  source_id: string;
  run_id: string;
  linked: number;
  moved: number;
  already_linked: number;
  deduped: number;
  skipped: Record<string, number>;
  queued_for_conflict: number;
  results: LinkRowResult[];
}

export const LINK_REASONS: Record<string, string> = {
  not_found: 'No fact with that id exists in this source.',
  no_page: 'No live page with that slug exists in this source. Link never creates a page.',
  inactive: 'The fact is expired, or its valid_until has passed.',
  withdrawn: 'This claim was explicitly forgotten for that entity, so it will not be attached there.',
  fence_malformed: 'The page the fact is leaving has a malformed ## Facts fence. Repair it, then rerun.',
  fence_drift: 'The fact records a fence row the page body does not have. Repair the fence, then rerun.',
  claim_unfenceable: 'The claim text cannot be written to a fence row unchanged (for example it is wrapped in ~~).',
  visibility_conflict: 'The entity already has the same claim from the same source with the other visibility.',
  revision_conflict: 'The fact or the entity page changed while link ran. Rerun.',
  page_file_missing: 'The entity page exists in the database but its file is missing from the source tree. Restore the file or run gbrain sync, then rerun.',
  unfenceable: 'The source writes through to files but has no canonical owner. Bind the source, then rerun.',
  no_page_publish: 'The target page disappeared before the write. Rerun.',
};

interface Stored {
  id: number; entity_slug: string | null; row_num: number | null; source_markdown_slug: string | null;
  expired_at: string | null; valid_until: string | null; fact: string; visibility: 'private' | 'world'; source: string | null;
}
interface Planned { fact: Stored; slug: string; movedFrom: string | null }

/** Parse a JSONL mapping file. A bad line refuses the whole file, before any write. */
export function parseLinkJsonl(text: string): { mappings: LinkMapping[] } | { error: string } {
  const mappings: LinkMapping[] = [];
  const seen = new Set<number>();
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!.trim();
    if (!line) continue;
    let row: unknown;
    try { row = JSON.parse(line); }
    catch { return { error: `line ${i + 1}: not valid JSON` }; }
    if (row === null || typeof row !== 'object' || Array.isArray(row)) return { error: `line ${i + 1}: expected an object with fact_id and slug` };
    const rec = row as Record<string, unknown>;
    const id = typeof rec.fact_id === 'number' ? rec.fact_id
      : typeof rec.fact_id === 'string' && /^\d+$/.test(rec.fact_id) ? Number(rec.fact_id) : NaN;
    if (!Number.isSafeInteger(id) || id < 1) return { error: `line ${i + 1}: fact_id must be a positive integer` };
    if (typeof rec.slug !== 'string') return { error: `line ${i + 1}: slug must be a string` };
    try { validatePageSlug(rec.slug); }
    catch (err) { return { error: `line ${i + 1}: ${err instanceof Error ? err.message : String(err)}` }; }
    if (seen.has(id)) return { error: `line ${i + 1}: fact_id ${id} is listed more than once` };
    seen.add(id);
    mappings.push({ fact_id: id, slug: rec.slug });
  }
  if (!mappings.length) return { error: 'the file has no mappings' };
  return { mappings };
}

const num = (v: unknown) => v == null ? null : Number(v);

function live(row: Stored, now: number): boolean {
  return row.expired_at === null && (row.valid_until === null || new Date(row.valid_until).getTime() > now);
}

export async function runFactsLink(engine: BrainEngine, opts: {
  sourceId: string; mappings: LinkMapping[]; dryRun?: boolean; conflictQueue?: boolean; config: GBrainConfig;
}): Promise<LinkReport> {
  const runId = randomUUID();
  const dryRun = opts.dryRun === true;
  const report: LinkReport = {
    schema_version: LINK_SCHEMA_VERSION, dry_run: dryRun, source_id: opts.sourceId, run_id: runId,
    linked: 0, moved: 0, already_linked: 0, deduped: 0, skipped: {}, queued_for_conflict: 0, results: [],
  };
  const bump = (row: LinkRowResult) => {
    report.results.push(row);
    if (row.status === 'linked') { report.linked += 1; if (row.moved_from) report.moved += 1; }
    else if (row.status === 'already_linked') report.already_linked += 1;
    else if (row.status === 'deduped') report.deduped += 1;
    else report.skipped[row.reason ?? 'revision_conflict'] = (report.skipped[row.reason ?? 'revision_conflict'] ?? 0) + 1;
  };
  const skip = (factId: number, slug: string, reason: string) => bump({ fact_id: factId, slug, status: 'skipped', reason });

  const ids = opts.mappings.map(m => m.fact_id);
  const stored = ids.length ? await engine.executeRaw<Stored & { id: number | string; row_num: number | string | null }>(
    `SELECT id, entity_slug, row_num, source_markdown_slug, expired_at, valid_until, fact, visibility, source
       FROM facts WHERE source_id = $1 AND id = ANY($2::bigint[])`, [opts.sourceId, ids]) : [];
  const byId = new Map(stored.map(r => [Number(r.id), { ...r, id: Number(r.id), row_num: num(r.row_num) }]));
  const slugs = [...new Set(opts.mappings.map(m => m.slug))];
  const fenceSlugs = [...new Set([...slugs, ...stored.map(r => r.source_markdown_slug).filter((s): s is string => !!s)])];
  const pages = fenceSlugs.length ? await engine.executeRaw<{ slug: string; compiled_truth: string | null }>(
    `SELECT slug, compiled_truth FROM pages WHERE source_id = $1 AND deleted_at IS NULL AND slug = ANY($2::text[])`,
    [opts.sourceId, fenceSlugs]) : [];
  const pageBySlug = new Map(pages.map(p => [p.slug, p.compiled_truth ?? '']));
  const now = Date.now();
  const planned: Planned[] = [];
  const seenClaim = new Set<string>();

  for (const mapping of opts.mappings) {
    const fact = byId.get(mapping.fact_id);
    if (!fact) { skip(mapping.fact_id, mapping.slug, 'not_found'); continue; }
    if (!live(fact, now)) { skip(mapping.fact_id, mapping.slug, 'inactive'); continue; }
    if (!pageBySlug.has(mapping.slug)) { skip(mapping.fact_id, mapping.slug, 'no_page'); continue; }
    const onTarget = fact.entity_slug === mapping.slug && (fact.source_markdown_slug === mapping.slug || (fact.source_markdown_slug === null && fact.row_num === null));
    if (onTarget) { bump({ fact_id: fact.id, slug: mapping.slug, status: 'already_linked' }); continue; }
    if (fact.row_num !== null || fact.source_markdown_slug !== null) {
      const from = fact.source_markdown_slug;
      if (!from || fact.row_num === null || !pageBySlug.has(from)) { skip(fact.id, mapping.slug, 'fence_drift'); continue; }
      const parsed = parseFactsFence(pageBySlug.get(from)!);
      if (parsed.warnings.length) { skip(fact.id, mapping.slug, 'fence_malformed'); continue; }
      if (!parsed.facts.some(f => f.rowNum === fact.row_num)) { skip(fact.id, mapping.slug, 'fence_drift'); continue; }
    }
    if (await isFactWithdrawn(engine, opts.sourceId, fact.visibility, fact.fact, mapping.slug)) {
      skip(fact.id, mapping.slug, 'withdrawn'); continue;
    }
    const claimKey = JSON.stringify([mapping.slug, fact.fact, fact.source ?? null]);
    const priorInBatch = seenClaim.has(claimKey);
    const [existing] = await engine.executeRaw<{ visibility: string }>(
      `SELECT visibility FROM facts WHERE source_id=$1 AND source_markdown_slug=$2 AND row_num IS NOT NULL
         AND expired_at IS NULL AND fact=$3 AND source IS NOT DISTINCT FROM $4 AND id <> $5 LIMIT 1`,
      [opts.sourceId, mapping.slug, fact.fact, fact.source ?? null, fact.id]);
    seenClaim.add(claimKey);
    if (existing && existing.visibility !== fact.visibility) { skip(fact.id, mapping.slug, 'visibility_conflict'); continue; }
    const movedFrom = fact.source_markdown_slug && fact.source_markdown_slug !== mapping.slug ? fact.source_markdown_slug : null;
    if (dryRun && (priorInBatch || existing)) {
      bump({ fact_id: fact.id, slug: mapping.slug, status: 'deduped', ...(movedFrom ? { moved_from: movedFrom } : {}) });
      continue;
    }
    planned.push({ fact, slug: mapping.slug, movedFrom });
  }

  if (dryRun) {
    for (const p of planned) bump({ fact_id: p.fact.id, slug: p.slug, status: 'linked', ...(p.movedFrom ? { moved_from: p.movedFrom } : {}) });
    return report;
  }

  const queue = opts.conflictQueue !== false && await conflictSlotOn(engine);
  const detached = await detachMoves(engine, opts, runId, planned, skip);
  const ready = planned.filter(p => detached.has(p.fact.id) || p.movedFrom === null);
  await publishLinks(engine, opts, report, runId, queue, ready, bump, skip);
  await logRun(engine, report);
  return report;
}

async function detachMoves(engine: BrainEngine, opts: { sourceId: string; config: GBrainConfig }, runId: string,
  planned: Planned[], skip: (factId: number, slug: string, reason: string) => void): Promise<Set<number>> {
  const ok = new Set<number>();
  const groups = new Map<string, Planned[]>();
  for (const p of planned) {
    if (!p.movedFrom) { ok.add(p.fact.id); continue; }
    groups.set(p.movedFrom, [...(groups.get(p.movedFrom) ?? []), p]);
  }
  for (const [slug, group] of groups) {
    const snaps = await readFacts(engine, opts.sourceId, group.map(p => p.fact.id));
    const facts: DetachIntentFact[] = [];
    for (const p of group) {
      const snap = snaps.find(s => s.id === p.fact.id);
      if (!snap || p.fact.row_num === null) { skip(p.fact.id, p.slug, 'revision_conflict'); continue; }
      facts.push({ id: p.fact.id, hash: relinkFactHash(snap), row_num: p.fact.row_num, note: `detached from ${slug} for an explicit link` });
    }
    if (!facts.length) continue;
    const result = await submitDetachGroup(engine, opts.config, opts.sourceId, slug, { kind: 'detach_fact', run_id: runId, facts });
    if (!result.ok) {
      const reason = /fence_drift/.test(result.message) ? 'fence_drift' : /fence_malformed/.test(result.message) ? 'fence_malformed' : result.reason === 'no_page' ? 'no_page_publish' : result.reason;
      for (const f of facts) skip(f.id, group.find(p => p.fact.id === f.id)!.slug, reason);
      continue;
    }
    const skipped = new Set(result.outcome.skipped.map(s => s.id));
    for (const f of facts) {
      if (skipped.has(f.id) || !result.outcome.detached.includes(f.id)) skip(f.id, group.find(p => p.fact.id === f.id)!.slug, 'fence_drift');
      else ok.add(f.id);
    }
  }
  return ok;
}

async function publishLinks(engine: BrainEngine, opts: { sourceId: string; config: GBrainConfig }, report: LinkReport, runId: string, queue: boolean,
  planned: Planned[], bump: (row: LinkRowResult) => void, skip: (factId: number, slug: string, reason: string) => void): Promise<void> {
  const groups = new Map<string, Planned[]>();
  for (const p of planned) groups.set(p.slug, [...(groups.get(p.slug) ?? []), p]);
  for (const [slug, group] of groups) {
    const snaps = await readFacts(engine, opts.sourceId, group.map(p => p.fact.id));
    const facts: RelinkIntentFact[] = [];
    const moved = new Map<number, string | undefined>();
    for (const p of group) {
      const snap = snaps.find(s => s.id === p.fact.id);
      if (!snap) { skip(p.fact.id, slug, 'revision_conflict'); continue; }
      facts.push({
        id: p.fact.id, hash: relinkFactHash(snap), tier: 'explicit', model: null, note: LINK_NOTE,
        from_entity: (snap.value.entity_slug ?? null) as string | null,
      });
      moved.set(p.fact.id, p.movedFrom ?? undefined);
    }
    if (!facts.length) continue;
    const result = await submitRelinkGroup(engine, opts.config, opts.sourceId, slug,
      { kind: 'relink_facts', run_id: runId, queue_conflict: queue, explicit: true, facts });
    if (!result.ok) {
      const reason = result.reason === 'no_page' ? 'no_page_publish' : result.reason;
      for (const f of facts) skip(f.id, slug, reason);
      continue;
    }
    const handled = new Set<number>();
    for (const l of result.outcome.linked) {
      handled.add(l.id);
      bump({ fact_id: l.id, slug, status: 'linked', ...(moved.get(l.id) ? { moved_from: moved.get(l.id) } : {}) });
    }
    for (const d of result.outcome.deduped) {
      handled.add(d.id);
      bump({ fact_id: d.id, slug, status: 'deduped', ...(moved.get(d.id) ? { moved_from: moved.get(d.id) } : {}) });
    }
    for (const s of result.outcome.skipped) { handled.add(s.id); skip(s.id, slug, s.reason); }
    for (const f of facts) if (!handled.has(f.id)) skip(f.id, slug, 'revision_conflict');
    report.queued_for_conflict += result.outcome.queued;
  }
}

async function conflictSlotOn(engine: BrainEngine): Promise<boolean> {
  const { loadConfigSnapshot } = await import('../config-snapshot.ts');
  const { readDecideConfig } = await import('../ai/decide/config.ts');
  const { hasTypesafeKey } = await import('../ai/decide/index.ts');
  const cfg = readDecideConfig(await loadConfigSnapshot(engine), { typesafeKey: hasTypesafeKey() });
  return cfg.slots.conflict.mode !== 'off';
}

async function logRun(engine: BrainEngine, report: LinkReport): Promise<void> {
  try {
    await engine.logIngest({
      source_id: report.source_id, source_type: 'facts:link', source_ref: report.run_id, pages_updated: [],
      summary: `link ${report.dry_run ? 'dry-run' : 'apply'}: linked ${report.linked} (${report.moved} moved), already ${report.already_linked}, deduped ${report.deduped}, skipped ${Object.values(report.skipped).reduce((n, v) => n + v, 0)}`,
    });
  } catch (err) {
    console.warn(`[facts:link] run summary not logged: ${err instanceof Error ? err.message : String(err)}`);
  }
}
