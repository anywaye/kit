# kit — the runtime credential-leak canary

> The contract is language-neutral and lives here. The adapters are
> per-language, one directory per language, and each one is a **reference
> implementation plus its own red proof** — not a sketch.

## Why this exists at all

Two scanners, and they do not overlap.

| Question | Answered by | Does it catch a runtime leak? |
|---|---|---|
| Was a credential **committed**? | a committed-history scanner | no |
| Does a credential **leave the process** while the tests run? | **nothing off the shelf** | — |

The second column is a finding, not a gap in the search. Measured:

- **gosec**'s `credentials.Match` switches on four AST node types and has **no
  `*ast.CallExpr` case**. It finds literals. A credential that leaks is a *value*
  that reached a `log.Info` call, and the value was never a literal — so the one
  tool whose job is Go security analysis structurally cannot see this.
- **Bandit** matches `ast.Constant` only. Same shape of limitation.
- **Brakeman**'s secret check is optional and off by default.
- Of **268 Semgrep taint rules, zero intersect CWE-532** (insertion of
  sensitive information into a log file).

So this had to be built. What follows is the smallest thing that is not a toy.

## The canary

A fake credential that is **unmistakably fake** and **unmistakably a
credential**: the prefix `cafaye_canary_` followed by 32 bytes. Plant it in the
service's own configuration, run the whole suite, then sweep for it everywhere it
could have gone.

**It is assembled at run time, never written as a literal.** That is a security
property, not a style one. A committed 46-character `cafaye_canary_…` is, to
every scanner in the world, a high-entropy credential-shaped string — it is
exactly what this repository's own `secrets` job is built to report, and
allowlisting it would be the precise failure the allowlist's
reason-per-entry rule exists to prevent. Because it is built, no allowlist
needs **no entry** for it. `TestCanaryIsSafe` asserts the absence directly, and
the tree-wide `canary_literal_check` in `tests/validate.sh` is the second half.

A harness must also be safe to point at a **real** credential, so no report,
failure message, or log line in this directory ever contains the planted value.
Every message is prefixed, truncated, or reduced to a position.

## The five vectors

Each has its own test, and each test runs **twice**: once against a type that
must come back clean, once against a deliberately defective type that must come
back **red**. The red half is in the same test as the clean half, so a detector
cannot be deleted from one half of the story.

| # | Vector | Asserts | Go adapter |
|---|---|---|---|
| 1 | **canary** | the value appears in no log record, no stdout, no stderr | `SweepOutput`, `SweepSinks` |
| 2 | **unknown-field sweep** | serialise it; no *unrecognised* key carries the value | `SweepSerialised` |
| 3 | **stringified-error sweep** | `%v`/`%+v`/`Sprint` over the whole error **chain** | `SweepErrorChain` |
| 4 | **absent-field sweep** | no credential-named key is marshalled **at all**, even empty | `SweepSerialised` |
| 5 | **Go type coverage** | no credential-bearing type implements `fmt.Stringer`/`error` | `TypeCoverage` |

Vectors 2 and 4 are separate because they fail for different reasons and a
single assertion cannot tell them apart. Vector 4 is green for a struct that is
behaving *perfectly*: it is checking a different question.

Vector 3 walks the chain, not the top error, because the top error is almost
never the one that leaks. The idiomatic Go error is a wrapper that adds context
and delegates, so the credential is usually in a leaf the caller never held
directly. The Go red proof leaks at **depth 1 of a 3-error chain** and the test
*fails if it ever stops leaking at depth > 0*, because a one-error chain is
exactly the case the vector does not exist for.

## Adopting it

**1. Copy the adapter for your language and keep the suite.**

```
templates/secrets/<lang>/     # codec + suite, like templates/otel/<lang>/
```

**2. Point the sweeps at your own sinks.** This is the part that cannot be
generic: the harness cannot enumerate a process's loggers, and pretending
otherwise is how a harness ends up asserting over three sinks out of nine.
Every adapter takes the sink list as an argument.

**3. Declare which keys are meant to be public.** `SweepSerialised` takes
`declaredSafe` as a parameter because only your service knows which of its keys
are meant to be public, and a harness that guessed would be asserting against the
wrong contract.

**4. Name your credential types.** Vector 5 matches on type *names*
(`SecretTypeNames`). A `token string` field is invisible to it — see the
`LIMITATION` note in `typecover.go`, and the measured reason.

**5. Run it in CI, on the full suite, with the canary planted.** A canary test
that only runs against a fixture is testing the fixture.

## What the Go adapter found, that no tool would have told you

The Go adapter exists partly because writing it produced findings. These are
measured, pinned by `print_shape_test.go`, and the reference type's shape is
derived from them.

**An unexported field is not protection.** `fmt` reaches unexported fields
through reflection and prints their values. The field being lowercase buys
nothing against `%v` — and `%v` is in every log line in every service. Neither
`-race` nor `go vet` mentions it.

**A `String()` method is *ignored* when the field is unexported.** `fmt` cannot
call a method on a value obtained from an unexported field, so it falls back to
reflection and prints the struct. A redacting `String()` is real protection in
an **exported** field and worth nothing in an unexported one. This is the one
that surprises people, because the redaction is right there in the code.

**The pointer shape is not a free lunch.** An unexported pointer field prints an
address under `%v`, which *looks* like the answer — and then `%s` and `%q` walk
the pointer and print the value anyway. A shape that is safe under the verb
everyone uses and unsafe under two others is worse than one that is obviously
broken, because it passes review.

**Numeric verbs leak for every field shape.** `%t`, `%e`, `%f`, `%g`, `%U` and
`%d` have no `Stringer` path, so `fmt` falls back to
`%!t(*Token=&{…})` — the value inside the error text.

**The hex verbs leak, reversibly.** `%x` prints `6361666179655f…`. Not readable
by a human, one `xxd -r -p` from a live secret. A table that called `%x` safe
would be wrong in the way that matters.

The only field shape safe under *every* verb is a `func() string` — and it has a
second property worth as much: `encoding/json` **refuses** to marshal it, so the
type cannot be serialised with the credential in it even by accident. It is
awkward for a credential read several times per request, which is why the
reference type is the pointer shape and the recommendation is `Claims`.

**And the actual answer, above all of them: don't hold the credential.** Pass
the `*Token` to the code that authenticates with it; keep only the subject and
the scopes in a struct that gets logged. `internal/safe.Claims` is that shape,
and it is the one kit points a service at first.

## Layout

```
templates/secrets/
├── README.md            # this file — the language-neutral contract
└── go/
    ├── canary.go        # the canary value, the sinks, the output sweep
    ├── sweep.go         # vectors 2, 3, 4
    ├── typecover.go     # vector 5, and its honest LIMITATION note
    ├── *_test.go        # the five vectors, each with its red proof
    └── internal/
        ├── safe/        # the reference shape to copy
        └── leaky/       # DO NOT COPY — one defect per vector, the red proof
```

`internal/leaky` is deliberately defective and lives under `internal/` so Go's own
import rules make it unreachable from outside the module. A service that copies
the template gets a package it cannot import and whose name says why it is there.

**Stdlib only. `GOPROXY=off`, no network, no `require` block** — enforced by a
check in `tests/validate.sh`, because kit has no dependencies and a template
that grows one stops being a template.

## Coverage, and what is NOT covered

Honest, and the reason this section exists.

- **Only Go has an adapter.** See `REPORT-kit-04-secrets.md` for the per-language
  status and why each missing one is missing. The contract above is what the
  other five adapters must implement; the Go one is the worked example and the
  only one currently proven.
- **Vector 5 is a type check, not a call-graph check.** It will not find a
  `String()` on a type whose secret is a plain `string` field, nor a method named
  `Render()` or `LogValue()`, nor anything in a dependency. Stated in
  `typecover.go`; it is a deliberate trade for needing no module and no
  resolver.
- **`SweepOutput` replaces `os.Stdout`/`os.Stderr`, not the file descriptors.**
  A logger holding its own dup of fd 1 bypasses it. A service that has one
  should point vector 1 at a `Sink` too, and say so.
- **A passing harness means no leak was *found*, not that none exists.** It
  asserts over the sinks and the packages you pointed it at.
