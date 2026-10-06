/**
 * `gbrain facts relink` (#5836): link facts saved without an entity to the
 * entity they are about. Trusted local CLI only; the work lives in
 * src/core/facts/relink.ts and src/core/facts/relink-publish.ts.
 */
import type { BrainEngine } from '../core/engine.ts';
import type { GBrainConfig } from '../core/config.ts';
import { readFileSync } from 'node:fs';
import { RELINK_DEFAULT_LIMIT, RELINK_DEFAULT_MAX_USD, runFactsRelink, type RelinkOptions, type RelinkReport } from '../core/facts/relink.ts';
import { RELINK_REASONS, type RelinkReason } from '../core/facts/relink-reasons.ts';
import { LINK_REASONS, parseLinkJsonl, runFactsLink, type LinkMapping, type LinkReport } from '../core/facts/link.ts';

export function factsHelpText(): string {
  return `Usage: gbrain facts <subcommand>

Subcommands:
  relink    Link facts saved without an entity to the person, company or
            project they are about, onto that entity page's ## Facts fence.
  link      Set or override one fact's entity page, or apply a JSONL mapping.
            Use this when you already know the page. Relink asks a model.

gbrain facts relink [flags]
  --source <id>          Source to repair (default: the resolved source)
  --dry-run              Show what would link; writes nothing, calls no model
  --limit <n>            Facts to examine this run (default ${RELINK_DEFAULT_LIMIT})
  --after-id <n>         Start after this fact id (the printed continuation point)
  --since <ISO date>     Only facts created on or after this date
  --no-llm               Free tiers only (recorded page, unique entity mention)
  --max-usd <n|off>      Cap for the model tier (default ${RELINK_DEFAULT_MAX_USD.toFixed(2)}); alias --max-cost-usd
  --retry-model          Ask the model again about facts it already judged
  --include-private      Also send private facts to the model tier
  --no-conflict-queue    Do not queue linked facts for the conflict sweep
  --examples <n>         Example facts per outcome (default 3)
  --json                 Machine-readable report (schema_version ${1})

gbrain facts link <fact-id> <page-slug> [flags]
gbrain facts link --file <mappings.jsonl> [flags]
  --source <id>          Source of the fact and the page (default: the resolved source)
  --file <path>          JSONL of {"fact_id": <id>, "slug": "<page-slug>"}; "-" reads stdin
  --dry-run              Show what would change; writes nothing
  --no-conflict-queue    Do not queue linked facts for the conflict sweep
  --json                 Machine-readable report (schema_version ${1})

Relink and link never create pages and never supersede a fact. The target page
must already exist in that source. Exact duplicates are retired (expired, kept
in history). A fact that lives on another page's fence is moved off it first.
Linked facts are queued for the System One conflict sweep when that slot is on.
Link does not call a model. Relink's free tiers cost nothing; its model tier
uses facts.extraction_model and stops at --max-usd.

On PGLite, one process owns the database file. If gbrain serve holds it, this
command fails with pglite_busy instead of writing around the lock. On a managed
brain the write goes through the same coordinator as other page writes.`;
}

interface ParsedArgs { opts: Omit<RelinkOptions, 'config'>; json: boolean; error?: string }

function parseRelinkArgs(args: string[], sourceId: string): ParsedArgs {
  const opts: Omit<RelinkOptions, 'config'> = { sourceId, maxUsd: RELINK_DEFAULT_MAX_USD };
  let json = false;
  const value = (i: number, flag: string): string => {
    const v = args[i + 1];
    if (v === undefined || v.startsWith('--')) throw new Error(`${flag} requires a value`);
    return v;
  };
  try {
    for (let i = 0; i < args.length; i++) {
      const a = args[i]!;
      if (a === '--json') json = true;
      else if (a === '--dry-run') opts.dryRun = true;
      else if (a === '--no-llm') opts.llm = false;
      else if (a === '--retry-model') opts.retryModel = true;
      else if (a === '--include-private') opts.includePrivate = true;
      else if (a === '--no-conflict-queue') opts.conflictQueue = false;
      else if (a === '--source') { opts.sourceId = value(i, a); i++; }
      else if (a === '--limit' || a === '--after-id' || a === '--examples') {
        const n = Number(value(i, a));
        if (!Number.isSafeInteger(n) || n < (a === '--after-id' || a === '--examples' ? 0 : 1)) throw new Error(`${a} must be a whole number`);
        if (a === '--limit') opts.limit = n; else if (a === '--after-id') opts.afterId = n; else opts.examples = n;
        i++;
      } else if (a === '--since') {
        const raw = value(i, a);
        const d = new Date(raw);
        if (!/^\d{4}-\d{2}-\d{2}/.test(raw) || Number.isNaN(d.getTime())) throw new Error('--since takes an ISO 8601 date (e.g. 2026-09-01); use --after-id for a fact id');
        opts.since = d;
        i++;
      } else if (a === '--max-usd' || a === '--max-cost-usd') {
        const raw = value(i, a);
        if (/^(off|unlimited|none)$/i.test(raw)) opts.maxUsd = null;
        else {
          const n = Number(raw);
          if (!Number.isFinite(n) || n < 0) throw new Error(`${a} takes a dollar amount or off`);
          opts.maxUsd = n;
        }
        i++;
      } else throw new Error(`unknown flag ${a}`);
    }
  } catch (err) {
    return { opts, json, error: err instanceof Error ? err.message : String(err) };
  }
  return { opts, json };
}

function continuation(report: RelinkReport, args: string[]): string | null {
  if (!report.has_more || report.next_after_id === null) return null;
  const kept: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--after-id') { i++; continue; }
    kept.push(args[i]!);
  }
  return `gbrain facts relink ${[...kept, '--after-id', String(report.next_after_id)].join(' ')}`;
}

export function formatRelinkReport(report: RelinkReport, args: string[]): string {
  const lines: string[] = [];
  const t = report.linked_by_tier;
  lines.push(`${report.dry_run ? 'DRY RUN: would link' : 'Linked'} ${report.linked} of ${report.scanned} unlinked fact(s) in source ${report.source_id}` +
    ` (page ${t.page}, mention ${t.mention}, model ${t.model}); ${report.deduped} exact duplicate(s) retired.`);
  if (!report.dry_run && report.linked) {
    lines.push(`Conflict sweep: ${report.queued_for_conflict} queued, ${report.eligible_for_conflict} eligible (have an embedding).`);
  }
  if (report.provider) {
    const cost = report.estimated_model_cost_usd == null ? 'unknown price' : `est. $${report.estimated_model_cost_usd.toFixed(4)}`;
    lines.push(`Model tier: ${report.facts_sent_to_model} fact(s) ${report.dry_run ? 'would go' : 'sent'} to ${report.provider} (${cost}` +
      `${report.dry_run ? '' : `, spent $${report.spend_usd.toFixed(4)}`}).` +
      (report.private_excluded_from_model ? ` ${report.private_excluded_from_model} private fact(s) held back (--include-private).` : ''));
  }
  const skipped = Object.entries(report.skipped) as Array<[RelinkReason, number]>;
  if (skipped.length) {
    lines.push('Not linked:');
    for (const [reason, n] of skipped.sort((a, b) => b[1] - a[1])) lines.push(`  ${reason}: ${n}. ${RELINK_REASONS[reason].fix}`);
  }
  if (report.fence_owned) lines.push(`  fence_owned: ${report.fence_owned} (not examined). ${RELINK_REASONS.fence_owned.fix}`);
  for (const [outcome, list] of Object.entries(report.examples)) {
    lines.push(`Examples (${outcome}):`);
    for (const e of list) lines.push(`  #${e.id} ${e.fact}${e.target ? ` -> ${e.target}` : ''}`);
  }
  if (report.stopped) lines.push(`Stopped early: ${report.stopped}.`);
  const next = continuation(report, args);
  if (next) lines.push(`More unlinked facts remain. Continue with:\n  ${next}`);
  else if (report.dry_run && report.linked) lines.push(`Apply with:\n  gbrain facts relink ${args.filter(a => a !== '--dry-run').join(' ')}`.trimEnd());
  return lines.join('\n');
}

function formatLinkReport(report: LinkReport, applyHint: string): string {
  const lines: string[] = [];
  const verb = report.dry_run ? 'DRY RUN: would link' : 'Linked';
  const retired = report.dry_run ? 'would retire' : 'retired';
  lines.push(`${verb} ${report.linked} fact(s) in source ${report.source_id}` +
    `${report.moved ? ` (${report.moved} moved off another page)` : ''}; ${report.already_linked} already linked; ${report.deduped} exact duplicate(s) ${retired}.`);
  if (!report.dry_run && report.linked) lines.push(`Conflict sweep: ${report.queued_for_conflict} queued.`);
  for (const row of report.results) {
    if (row.status === 'skipped') lines.push(`  #${row.fact_id} ${row.reason}: ${LINK_REASONS[row.reason ?? ''] ?? row.reason}`);
    else if (row.status === 'already_linked') lines.push(`  #${row.fact_id} already linked to ${row.slug}`);
    else lines.push(`  #${row.fact_id} ${row.status === 'deduped' ? (report.dry_run ? 'duplicate, would retire onto' : 'duplicate, retired onto') : '->'} ${row.slug}${row.moved_from ? ` (from ${row.moved_from})` : ''}`);
  }
  if (report.dry_run && (report.linked || report.deduped)) lines.push(`Apply with:\n  ${applyHint}`);
  return lines.join('\n');
}

function parseLinkArgs(args: string[], sourceId: string): { mappings?: LinkMapping[]; dryRun: boolean; json: boolean; conflictQueue: boolean; sourceId: string; applyHint: string; error?: string } {
  let dryRun = false;
  let json = false;
  let conflictQueue = true;
  let file: string | undefined;
  const positional: string[] = [];
  const kept: string[] = [];
  try {
    for (let i = 0; i < args.length; i++) {
      const a = args[i]!;
      if (a === '--json') { json = true; kept.push(a); }
      else if (a === '--dry-run') { dryRun = true; kept.push(a); }
      else if (a === '--no-conflict-queue') { conflictQueue = false; kept.push(a); }
      else if (a === '--source') {
        const v = args[i + 1];
        if (v === undefined || v.startsWith('--')) throw new Error('--source requires a value');
        sourceId = v;
        kept.push(a, v);
        i++;
      } else if (a === '--file') {
        const v = args[i + 1];
        if (v === undefined || (v.startsWith('--') && v !== '-')) throw new Error('--file requires a path, or - for stdin');
        file = v;
        kept.push(a, v);
        i++;
      } else if (a.startsWith('--')) throw new Error(`unknown flag ${a}`);
      else positional.push(a);
    }
    let mappings: LinkMapping[];
    if (file !== undefined) {
      if (positional.length) throw new Error('pass either <fact-id> <page-slug> or --file, not both');
      const text = file === '-' ? readFileSync(0, 'utf8') : readFileSync(file, 'utf8');
      const parsed = parseLinkJsonl(text);
      if ('error' in parsed) throw new Error(parsed.error);
      mappings = parsed.mappings;
    } else {
      if (positional.length !== 2) throw new Error('usage: gbrain facts link <fact-id> <page-slug> or gbrain facts link --file <mappings.jsonl>');
      const id = Number(positional[0]);
      if (!Number.isSafeInteger(id) || id < 1) throw new Error('fact-id must be a positive integer');
      const parsed = parseLinkJsonl(JSON.stringify({ fact_id: id, slug: positional[1] }));
      if ('error' in parsed) throw new Error(parsed.error);
      mappings = parsed.mappings;
    }
    const applyHint = `gbrain facts link ${[...kept.filter(a => a !== '--dry-run'), ...positional].join(' ')}`.trimEnd();
    return { mappings, dryRun, json, conflictQueue, sourceId, applyHint };
  } catch (err) {
    return { dryRun, json, conflictQueue, sourceId, applyHint: '', error: err instanceof Error ? err.message : String(err) };
  }
}

/** Exit code: 0 for complete and partial runs (limit or budget), 1 for usage errors. */
export async function runFactsCommand(engine: BrainEngine, args: string[], config: GBrainConfig, sourceId: string): Promise<number> {
  const sub = args[0];
  if (!sub || sub === '--help' || sub === '-h') {
    console.log(factsHelpText());
    return 0;
  }
  if (sub !== 'relink' && sub !== 'link') {
    console.error(`gbrain facts: unknown subcommand ${sub}\n\n${factsHelpText()}`);
    return 1;
  }
  if (sub === 'link') {
    const rest = args.slice(1);
    if (rest.includes('--help') || rest.includes('-h')) { console.log(factsHelpText()); return 0; }
    const parsed = parseLinkArgs(rest, sourceId);
    if (parsed.error || !parsed.mappings) {
      console.error(`gbrain facts link: ${parsed.error ?? 'no mappings'}`);
      return 1;
    }
    const report = await runFactsLink(engine, {
      sourceId: parsed.sourceId, mappings: parsed.mappings, dryRun: parsed.dryRun,
      conflictQueue: parsed.conflictQueue, config,
    });
    console.log(parsed.json ? JSON.stringify(report, null, 2) : formatLinkReport(report, parsed.applyHint));
    return 0;
  }
  const rest = args.slice(1);
  if (rest.includes('--help') || rest.includes('-h')) {
    console.log(factsHelpText());
    return 0;
  }
  const parsed = parseRelinkArgs(rest, sourceId);
  if (parsed.error) {
    console.error(`gbrain facts relink: ${parsed.error}`);
    return 1;
  }
  const isTty = process.stderr.isTTY === true;
  const report = await runFactsRelink(engine, {
    ...parsed.opts, config,
    onModelStart: line => process.stderr.write(`[facts relink] ${line}\n`),
    onProgress: isTty ? (done, total) => { if (done === total || done % 100 === 0) process.stderr.write(`\r[facts relink] free tiers ${done}/${total}`); if (done === total) process.stderr.write('\n'); } : undefined,
  });
  console.log(parsed.json ? JSON.stringify({ ...report, next_command: continuation(report, rest) }, null, 2) : formatRelinkReport(report, rest));
  return 0;
}
