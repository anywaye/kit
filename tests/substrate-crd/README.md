# substrate-crd — the pinned CRDs' field names, so the gate can grade a manifest

## Why this directory exists

The substrate's Postgres Cluster was applied on the box and refused:

```
Error from server (BadRequest): error when creating ".../manifests/data/postgres-cluster.yaml":
Cluster in version "v1" cannot be handled as a Cluster: strict decoding error:
unknown field "spec.storageConfiguration"
```

`storageConfiguration` is CNPG's **pre-1.24** name. The operator the installer
pins — `CNPG_VERSION="v1.30.1"` in `templates/substrate/install.sh` — declares
`spec.storage`, and its CRD is structural, so the API server refuses the object
rather than dropping the unknown key. Every check in `tests/substrate_test.sh`
passed on that file, including one that asserted `spec.storageConfiguration.size`
in so many words: a check written from the manifest it grades can never disagree
with it.

`schemas.json` is what lets a check disagree with the manifest, because the
allowed names come from the **operator**, not from the manifest.

## What is here

- **`schemas.json`** — the property-name graph of each pinned CRD's `spec`, plus
  the pin and release URL each was derived from. Encoding, stated in the file's
  own `note`: an object is `{key: model}`, an array is `{"[]": model}`, a
  primitive is `true`, and a node whose keys the CRD leaves open
  (`additionalProperties`, `x-kubernetes-preserve-unknown-fields`) is `"*"` — or
  the key `"*"` inside an object that names some keys and leaves the rest open.
  It is a **name** graph, not a type graph: it catches a field name the pinned
  CRD does not declare, which is the strict-decoding half of what the API server
  enforces, and nothing more.
- **`regen.py`** — how `schemas.json` is produced. It reads the three operator
  pins out of `install.sh`, fetches each release manifest from the same URL the
  installer applies, and writes the graph.

## The rule that keeps it honest

`tests/substrate_test.sh` §9b compares the `version` in `schemas.json` against
the pin in `install.sh` and **fails** if they disagree. Bumping
`CNPG_VERSION` (or Argo CD's, or cert-manager's) without re-deriving the model is
therefore a red gate, not a manifest graded against a schema nobody re-fetched.

Re-derive after a pin bump:

```sh
python3 tests/substrate-crd/regen.py
```

## Not run by the gate, on purpose

`regen.py` needs the network; the gate does not. The gate reads the committed
`schemas.json` and stays offline, the same as the rest of `substrate_test.sh`.
`regen.py` is a development tool, is not invoked by `validate.sh`, and imports
PyYAML only — which the gate's own `.venv` already provides.
