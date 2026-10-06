/**
 * `gbrain facts link`: an operator mapping sets or overrides a fact's entity
 * page through the write coordinator. The target page must already exist.
 * A fact on another page's fence moves. Dry-run writes nothing. Doctor's
 * unlinked count follows entity_slug.
 */
import { describe, test, expect, beforeAll, beforeEach, afterAll } from 'bun:test';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PGLiteEngine } from '../src/core/pglite-engine.ts';
import { importFromContent } from '../src/core/import-file.ts';
import { parseFactsFence } from '../src/core/facts-fence.ts';
import { parseLinkJsonl, runFactsLink } from '../src/core/facts/link.ts';
import { runFactsCommand } from '../src/commands/facts.ts';
import { recordFactWithdrawal } from '../src/core/facts/withdrawal.ts';
import { unlinkedFactsStats } from '../src/commands/doctor/checks/unlinked-facts.ts';
import { resetPgliteState } from './helpers/reset-pglite.ts';
import { managedBrain } from './helpers/managed-brain.ts';

let engine: PGLiteEngine;
const config = { engine: 'pglite' } as never;

async function unlinked(fact: string, extra: Record<string, unknown> = {}): Promise<number> {
  const r = await engine.insertFact({ fact, kind: 'fact', entity_slug: null, visibility: 'world', source: 'chat 2026-10-01', ...extra } as never,
    { source_id: 'default' });
  return r.id;
}
const row = async (id: number) => (await engine.executeRaw<Record<string, unknown>>('SELECT * FROM facts WHERE id = $1', [id]))[0]!;
const link = (mappings: Array<{ fact_id: number; slug: string }>, extra: Record<string, unknown> = {}) =>
  runFactsLink(engine, { sourceId: 'default', mappings, config, ...extra });

beforeAll(async () => {
  engine = new PGLiteEngine();
  await engine.connect({});
  await engine.initSchema();
}, 120_000);
afterAll(async () => { await engine.disconnect(); });
beforeEach(async () => {
  await resetPgliteState(engine);
  await engine.setConfig('decide.slots.conflict.mode', 'off');
  await importFromContent(engine, 'companies/acme-example', '---\ntitle: Acme Example\ntype: company\n---\n\n# Acme Example\n\nA company.\n', { noEmbed: true });
  await importFromContent(engine, 'people/alice-example', '---\ntitle: Alice Example\ntype: person\n---\n\n# Alice Example\n', { noEmbed: true });
});

describe('parseLinkJsonl', () => {
  test('rejects a bad line, a duplicate id, and an empty file before any write', () => {
    expect(parseLinkJsonl('{nope')).toEqual({ error: 'line 1: not valid JSON' });
    expect('error' in parseLinkJsonl('{"fact_id": 1}\n') && parseLinkJsonl('{"fact_id": 1}\n').error).toMatch(/slug/);
    const dup = parseLinkJsonl('{"fact_id": 4, "slug": "people/alice-example"}\n{"fact_id": "4", "slug": "companies/acme-example"}');
    expect('error' in dup && dup.error).toMatch(/more than once/);
    expect(parseLinkJsonl('\n\n')).toEqual({ error: 'the file has no mappings' });
    const ok = parseLinkJsonl('{"fact_id": "12", "slug": "people/alice-example"}\n');
    expect(ok).toEqual({ mappings: [{ fact_id: 12, slug: 'people/alice-example' }] });
  });
});

describe('facts link', () => {
  test('sets entity_slug on the existing page fence and the doctor count drops', async () => {
    const id = await unlinked('shipped the widget on Tuesday');
    const before = await unlinkedFactsStats(engine, ['default']);
    expect(before!.window.unlinked).toBe(1);
    const dry = await link([{ fact_id: id, slug: 'companies/acme-example' }], { dryRun: true });
    expect(dry.dry_run).toBe(true);
    expect(dry.linked).toBe(1);
    expect((await row(id)).entity_slug).toBeNull();
    const report = await link([{ fact_id: id, slug: 'companies/acme-example' }]);
    expect(report.linked).toBe(1);
    expect(report.results[0]).toMatchObject({ fact_id: id, slug: 'companies/acme-example', status: 'linked' });
    const r = await row(id);
    expect(r.entity_slug).toBe('companies/acme-example');
    expect(r.source_markdown_slug).toBe('companies/acme-example');
    expect(Number(r.row_num)).toBeGreaterThan(0);
    expect(r.context).toBe('entity linked by operator');
    expect(r.expired_at).toBeNull();
    const page = await engine.getPage('companies/acme-example', { sourceId: 'default' });
    const cell = parseFactsFence(page!.compiled_truth).facts.find(f => f.rowNum === Number(r.row_num));
    expect(cell?.claim).toBe('shipped the widget on Tuesday');
    const after = await unlinkedFactsStats(engine, ['default']);
    expect(after!.window.unlinked).toBe(0);
    expect(after!.relinked_7d).toMatchObject({ explicit: 1 });
    const again = await link([{ fact_id: id, slug: 'companies/acme-example' }]);
    expect(again.already_linked).toBe(1);
    expect(await engine.executeRaw<{ n: number }>(`SELECT COUNT(*)::int AS n FROM facts WHERE fact = 'shipped the widget on Tuesday' AND expired_at IS NULL`))
      .toEqual([{ n: 1 }]);
  });

  test('overrides a wrong entity slug without creating a page', async () => {
    const id = await unlinked('keeps the books', { entity_slug: 'people/nobody-example' });
    expect((await row(id)).entity_slug).toBe('people/nobody-example');
    const missing = await link([{ fact_id: id, slug: 'people/nobody-example' }]);
    expect(missing.results[0]!.reason).toBe('no_page');
    expect(await engine.getPage('people/nobody-example', { sourceId: 'default' })).toBeNull();
    expect((await row(id)).entity_slug).toBe('people/nobody-example');
    const report = await link([{ fact_id: id, slug: 'people/alice-example' }]);
    expect(report.linked).toBe(1);
    expect((await row(id)).entity_slug).toBe('people/alice-example');
    expect(await engine.getPage('people/nobody-example', { sourceId: 'default' })).toBeNull();
  });

  test('moves a fact off another page fence and does not leave a copy behind', async () => {
    const id = await unlinked('introduced the round');
    await link([{ fact_id: id, slug: 'people/alice-example' }]);
    const report = await link([{ fact_id: id, slug: 'companies/acme-example' }]);
    expect(report.linked).toBe(1);
    expect(report.moved).toBe(1);
    expect(report.results[0]!.moved_from).toBe('people/alice-example');
    const r = await row(id);
    expect(r.entity_slug).toBe('companies/acme-example');
    expect(r.expired_at).toBeNull();
    expect(String(r.context)).toContain('entity linked by operator');
    const alice = parseFactsFence((await engine.getPage('people/alice-example', { sourceId: 'default' }))!.compiled_truth);
    const acme = parseFactsFence((await engine.getPage('companies/acme-example', { sourceId: 'default' }))!.compiled_truth);
    expect(alice.facts.filter(f => f.active && f.claim === 'introduced the round')).toHaveLength(0);
    expect(acme.facts.filter(f => f.active && f.claim === 'introduced the round')).toHaveLength(1);
    const active = await engine.executeRaw<{ n: number }>(`SELECT COUNT(*)::int AS n FROM facts WHERE id = $1 AND expired_at IS NULL`, [id]);
    expect(active[0]!.n).toBe(1);
  });

  test('a page that exists only in another source is not a target and no stub is created', async () => {
    await engine.executeRaw(`INSERT INTO sources (id, name) VALUES ('other', 'other') ON CONFLICT DO NOTHING`);
    await importFromContent(engine, 'people/charlie-example', '---\ntitle: Charlie Example\ntype: person\n---\n\n# Charlie Example\n', { noEmbed: true, sourceId: 'other' });
    const id = await unlinked('met Charlie Example');
    const report = await link([{ fact_id: id, slug: 'people/charlie-example' }]);
    expect(report.results[0]).toMatchObject({ status: 'skipped', reason: 'no_page' });
    expect((await row(id)).entity_slug).toBeNull();
    expect(await engine.getPage('people/charlie-example', { sourceId: 'default' })).toBeNull();
    expect(await engine.getPage('people/charlie-example', { sourceId: 'other' })).not.toBeNull();
  });

  test('a withdrawn claim is not attached', async () => {
    const original = await unlinked('Acme Example raised a seed round');
    await link([{ fact_id: original, slug: 'companies/acme-example' }]);
    await recordFactWithdrawal(engine, original, 'default');
    const id = await unlinked('Acme Example raised a seed round');
    const report = await link([{ fact_id: id, slug: 'companies/acme-example' }]);
    expect(report.results[0]!.reason).toBe('withdrawn');
    expect((await row(id)).entity_slug).toBeNull();
  });

  test('an exact duplicate is retired and a JSONL file drives the command', async () => {
    const keep = await unlinked('closed the round');
    await link([{ fact_id: keep, slug: 'companies/acme-example' }]);
    const dup = await unlinked('closed the round');
    const dir = mkdtempSync(join(tmpdir(), 'gbrain-facts-link-'));
    const file = join(dir, 'mappings.jsonl');
    writeFileSync(file, `{"fact_id": ${dup}, "slug": "companies/acme-example"}\n{"fact_id": 999999, "slug": "people/alice-example"}\n`);
    const code = await runFactsCommand(engine, ['link', '--file', file, '--json', '--dry-run'], config, 'default');
    expect(code).toBe(0);
    expect((await row(dup)).entity_slug).toBeNull();
    const applied = await runFactsCommand(engine, ['link', '--file', file], config, 'default');
    expect(applied).toBe(0);
    expect((await row(dup)).expired_at).not.toBeNull();
    expect((await row(dup)).entity_slug).toBe('companies/acme-example');
    expect((await row(keep)).expired_at).toBeNull();
    const bad = await runFactsCommand(engine, ['link', '--file', file, '1', 'people/alice-example'], config, 'default');
    expect(bad).toBe(1);
  });
});

test('managed brain: a raw fact update is refused and facts link still publishes', async () => {
  await managedBrain(async ({ engine: managed }) => {
    await managed.setConfig('sync.write_through', 'false');
    await managed.setConfig('decide.slots.conflict.mode', 'off');
    const [idRow] = await managed.executeRaw<{ id: number | string }>(
      `SELECT id FROM facts WHERE fact = 'keeps the books' AND source_id = 'default'`);
    const id = Number(idRow!.id);
    await expect(managed.executeRaw(`UPDATE facts SET entity_slug = 'people/alice-example' WHERE id = $1`, [id]))
      .rejects.toThrow(/writer_coordinator_required/);
    const report = await runFactsLink(managed, {
      sourceId: 'default', config, mappings: [{ fact_id: id, slug: 'people/alice-example' }],
    });
    expect(report.linked).toBe(1);
    const [after] = await managed.executeRaw<{ entity_slug: string }>(`SELECT entity_slug FROM facts WHERE id = $1`, [id]);
    expect(after!.entity_slug).toBe('people/alice-example');
    expect(await managed.getPage('people/made-up', { sourceId: 'default' })).toBeNull();
  }, {
    setup: async ({ engine: setup }) => {
      await importFromContent(setup, 'people/alice-example', '---\ntitle: Alice Example\ntype: person\n---\n\n# Alice Example\n', { noEmbed: true });
      await setup.insertFact({ fact: 'keeps the books', kind: 'fact', entity_slug: null, visibility: 'world', source: 'chat 2026-10-01' } as never,
        { source_id: 'default' });
    },
  });
});
