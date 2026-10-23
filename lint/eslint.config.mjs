// kit's ESLint config, used FROM kit at run time:
//   eslint --config <repo>/.kit/lint/eslint.config.mjs .
//
// It is not copied into a service repo. See README.md, "Where the lint configs
// run" — the mechanism is a `uses:` and a checkout, not a `cp`.
//
// READ THE TWO BLOCKS BELOW BEFORE LOOSENING ANYTHING. Both of them are the
// result of a measured failure in a service that did nothing wrong, and both
// were invisible here for the same reason: a file this repository only ever
// parsed is a file nobody ever RAN against a real project.
//
// `files` MUST COVER EVERY EXTENSION typescript-eslint's recommended sets pull
// in, and `tsconfigRootDir` MUST BE THE CALLER'S WORKSPACE. They are two halves
// of one property — EVERY linted file gets type information — and each half
// alone leaves the other to fail.
//
// WHAT WAS ACTUALLY WRONG, because the reported diagnosis was wrong and the
// wrong one is worth recording. The failure in anywaye/site run 37236386666 and
// anywaye/parlor run 37230458669 was
//
//   Error: Error while loading rule '@typescript-eslint/await-thenable':
//   You have used a rule which requires type information, but don't have
//   parserOptions set to generate type information for this file.
//
// and it was attributed to `tsconfigRootDir: import.meta.dirname` — kit's
// directory rather than the caller's. That is a real misconfiguration and it is
// fixed here, but it is NOT what produced that error. Measured, on eslint 9.39.5
// with typescript-eslint 8: with `projectService: true`, setting
// `tsconfigRootDir` to `/nonexistent-root`, or removing it entirely, leaves the
// run byte-identical. The project service walks UP from the linted FILE to find
// a tsconfig; it does not start from tsconfigRootDir.
//
// The real cause is a GLOB MISMATCH, and it is this:
//
//   this file's `files`      **/*.{js,mjs,cjs,ts,tsx}
//   typescript-eslint's      **/*.ts,**/*.tsx,**/*.mts,**/*.cts
//     `eslint-recommended`
//
// `tseslint.configs.recommendedTypeChecked` contains a config object whose
// `files` adds `.mts` and `.cts` to the set of files ESLint will lint. Our own
// `files` then supplied `parserOptions` — the only source of type information —
// to a NARROWER set that excludes both. So every `.mts` file was linted, was
// given the type-aware rules, and was never given the type information those
// rules require. `@typescript-eslint/await-thenable` is simply the first rule to
// be constructed; the whole `recommendedTypeChecked` set is affected, and the
// run dies at exit 2 before reporting a single finding.
//
// Both anywaye/site and anywaye/parlor carry three `.mts` files each at the repo
// root — vitest.config.mts, vite.config.mts, vite.node.config.mts — which is
// why this was never a marginal case.
//
// The general rule, and it is the one worth keeping: **`recommendedTypeChecked`
// is UNSCOPED, so `files` is load-bearing.** A config with no `files` applies to
// every linted extension; that is the warning this file used to carry about the
// `files` scope being too NARROW, and it was half a warning. The scope has to
// be at least as wide as the recommended sets, or type-aware rules land on files
// that were never given type information.
//
// WHY `tsconfigRootDir` IS STILL FIXED HERE, since it was not the reported
// cause. It is load-bearing in exactly one place, and it is a place kit would
// otherwise reach for: `allowDefaultProject`'s globs are matched RELATIVE TO
// `tsconfigRootDir` (measured — `useProgramFromProjectService.js` does
// `path.relative(parseSettings.tsconfigRootDir, filePathAbsolute)` and matches
// that). With kit's directory as the root, a pattern meant to cover the
// CALLER's root config files resolves to `.kit/lint/*.mts` and matches nothing;
// the error even says so, `allowDefaultProject is set to ["*.mts"], which does
// not match '../../probe.mts'`. So the value is wrong in a way that is invisible
// until the first time anybody adds an `allowDefaultProject` entry, which is
// precisely the kind of latent defect this file is written to not carry.
//
// `process.cwd()` and not an input, deliberately. ESLint resolves files
// relative to its base path and walks up from the CWD looking for a project
// root, so the caller's workspace IS the CWD by the time this file is read — and
// tests/lint_test.sh asserts that requirement rather than describing it. Adding
// a workflow input would mean every caller in the fleet needed a PR to fix a
// path that is already correct in the environment. It must be ABSOLUTE
// (measured: a relative value is rejected outright with `parserOptions.
// tsconfigRootDir must be an absolute path`), which `process.cwd()` always is.
//
//   - Flat config only (`eslint.config.mjs`), no .eslintrc: ESLint 9 reads
//     nothing else, so a repo with an .eslintrc is silently unlinted.
//   - We start from `js.configs.recommended` and then turn the rules that
//     matter for a TypeScript service on explicitly. Recommended alone does NOT
//     catch `no-floating-promises` (needs type info) or `eqeqeq` relaxations.
//   - No `node_modules` ignore entry on purpose: ESLint 9 ignores it by default
//     and a redundant ignore is one more thing to keep in sync.
//
//   - `.kit/**` is ignored, and this line exists because of a measured failure
//     rather than a preference. typescript-eslint's project service has to place
//     EVERY linted file inside a tsconfig, and when this config is loaded from
//     `.kit/lint/` it is itself a linted file that belongs to none. Without the
//     ignore the run is red with
//         Parsing error: …/.kit/lint/eslint.config.mjs was not found by the
//         project service
//     which is a build failure about kit's own file, in a service that did
//     nothing wrong, on a config the service never wrote. Carried here rather
//     than left to each service, because the file is the service's problem the
//     moment it is not ours.
//
//   - `.jsx` is DELIBERATELY still absent, and its absence is load-bearing. No
//     config above adds it to the linted set, so adding it here would widen what
//     kit lints in every service in the fleet — and a `.jsx` file is not in
//     anyone's tsconfig either, so every one of them would go red with
//     `was not found by the project service` (measured). A TypeScript service's
//     React components are `.tsx`. Widening this glob is not a free act; see
//     `eslint_typed_scope_check` in tests/validate.sh, which asserts the set is
//     at least as wide as the recommended sets and not wider by accident.
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['dist/**', 'build/**', 'coverage/**', '.kit/**'],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    // Every extension `recommendedTypeChecked` can hand a type-aware rule. Read
    // as a set rather than as a convenience: see the block comment above for the
    // mismatch that shipped when this list was four extensions short of it.
    files: ['**/*.{js,mjs,cjs,ts,tsx,mts,cts}'],
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: process.cwd() },
    },
    rules: {
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-console': ['error', { allow: ['warn', 'error'] }],
      'prefer-const': 'error',
      'no-return-await': 'error',
    },
  },
);
