# REPORT-kit-license-m168 — Kit's first-party grant moves to Cafaye proprietary terms

## What this packet did

Kit's own grant was MIT. It is now the canonical Cafaye proprietary text,
byte-identical to `/Users/kaka/Code/any/moon/cafaye/identity/LICENSE`.
No rights-holder conflict: kit's old header read `Copyright (c) 2026 cafaye`;
identity's reads `Copyright (c) 2026 Cafaye`. Same holder, so the copy
proceeded; had they named different holders the packet would have stopped.

## Changed files

- `LICENSE` — replaced whole with the identity text (8 insertions, 19 deletions).
- `README.md` — four spots, grant claim only:
  - layout-table `LICENSE` row: "kit's own grant: MIT" → "kit's own grant:
    Cafaye proprietary".
  - `### kit's own licence`: "kit itself is MIT" → "kit itself is Cafaye
    proprietary"; "granted MIT … under MIT" → "granted under the proprietary
    terms in `LICENSE` … under those terms".
  - `## License`: "MIT. See LICENSE" → "Proprietary — Cafaye. See LICENSE".
  - Same section's check paragraph: "reads the grant by MIT's own sentences
    rather than by the string `MIT`" → "reads the grant by the proprietary
    sentences in `LICENSE` rather than by an identifier string".
- `AGENTS.md` — two spots:
  - layout comment: `# MIT. The whole grant …` → `# Proprietary (Cafaye).
    The whole grant …`.
  - rules bullet: "The licence is MIT, and it lives in exactly one place" →
    "The licence is Cafaye proprietary, and it lives in exactly one place".
- `REPORT-kit-license-m168.md` (this file).

## Focused checks and results

- `cmp LICENSE /Users/kaka/Code/any/moon/cafaye/identity/LICENSE` → identical,
  no output (PASS).
- `git diff --check` → clean, no whitespace errors (PASS).
- Bounded `rg -n -w "MIT"` review over the tree after the edit: the only
  remaining word-boundary `MIT` hits are third-party notices, vendored-stack
  comments, or historical records (listed below). No current first-party Kit
  grant claim remains (PASS).
- No metadata edit touched a manifest, so no syntax check was made necessary.
  (There is no `package.json`, `Cargo.toml`, `pyproject.toml`, gemspec, or
  other root manifest carrying a licence field — verified by listing the root.)
- Deliberately NOT run: `bash tests/validate.sh`, Docker, prime, chart/image
  builds, releases. Packet scope is metadata/legal text.

## Preserved third-party notices (untouched, with reason)

- `README.md` AGPL paragraph ("compatible with cafaye being MIT/Apache … the
  obligation runs one way") — technical compatibility explanation for the
  unmodified Grafana/Loki/Tempo backends. Preserved per packet.
- `templates/compose/docker-compose.yml` (AGPL compat comment, HyperDX-UI MIT
  / ClickHouse Apache-2.0 notes), `templates/compose/.env.example` (same
  HyperDX/ClickHouse note), provisioned Grafana dashboard JSON (embeds the
  AGPL-compat paragraph — it ships inside the fetched stack), and
  `templates/database/tenancy/advisor.sql` (Supabase `pg-meta` MIT-licensed,
  explicitly NOT copied). All describe third-party terms; none claims Cafaye
  owns third-party work, and none was touched.
- `CHANGELOG.md`, `DECISIONS.md`, `REPORT-kit-19.md` and other historical
  reports: they record that kit-19 granted MIT. History, preserved as-is.

## Historical-MIT limitation (residual language, recorded not edited)

- Older commits granted MIT, and history still says so. Nothing in this packet
  rewrites that, and a reader of the changelog will correctly conclude kit
  *was* MIT before this change. The grant in force is `LICENSE` at HEAD.
- Residual fleet-scope claims intentionally left alone as out of scope: the
  "cafaye being MIT/Apache" phrasing (README AGPL paragraph, compose comments,
  dashboard JSON) speaks about the fleet/services, not Kit's own grant. If the
  proprietary decision extends fleet-wide, a follow-up packet should revisit
  those lines; this one does not claim Cafaye owns third-party work and does
  not relicense any other repository.

## Pre-existing discrepancy found (not introduced, flagged for follow-up)

- `README.md` (table row, `## License` section) and `AGENTS.md` (licence rule)
  describe a gate `license_check` that "reads the grant" and "walks every root
  manifest". No `license_check` exists anywhere under `tests/` or
  `.github/` — `rg license_check tests/ .github/` returns nothing. The prose
  was kept (with the grant reference re-pointed) and this gap recorded rather
  than fixed here, because adding or re-pointing a gate check is a gate change
  outside this packet's metadata-only scope and would demand a full gate run
  this packet forbids. Recommended follow-up: either implement the check
  against the proprietary sentences or correct the prose to match the gate.
