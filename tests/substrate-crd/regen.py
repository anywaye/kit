#!/usr/bin/env python3
"""Re-derive schemas.json from the CRDs the installer pins.

NOT RUN BY THE GATE. `tests/substrate_test.sh` reads the committed
`schemas.json`; this program is how that file is produced, and it needs the
network. It exists so that a pin bump is a reproducible edit rather than a
hand-typed field list that nobody can defend.

    python3 tests/substrate-crd/regen.py

It reads the three operator pins out of `templates/substrate/install.sh`,
fetches each operator's release manifest from the *same* pinned URL the
installer uses, and writes the property-name graph of each CRD's `spec` — see
`schemas.json`'s own `note` for the encoding.

Why the model is derived and not hand-written: a hand-typed list of "known
fields" is a statement about what the manifest already says, and it therefore
contains every field the manifest has — including a wrong one. Deriving it from
the CRD is what makes `storageConfiguration` (a name CNPG retired before
1.24) fail a check instead of satisfying it.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
INSTALL = HERE.parent.parent / "templates/substrate/install.sh"
OUT = HERE / "schemas.json"

# pin name -> (CRD metadata.name, release-manifest URL template)
# ARGOCD_VERSION appears twice because core-install ships two CRDs the substrate
# uses — Application and AppProject — and the AppProject is what the packet's
# defect is about: core-install's CRD but no object, so the Applications'
# `spec.project: default` never syncs. Both CRDs come from the same pinned
# manifest, so the pin is one fact with two models; the sources dict keeps the
# pin's version beside each key so a bump without re-deriving still goes red.
TARGETS = {
    "CNPG_VERSION": (
        "clusters.postgresql.cnpg.io",
        "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/{v}/releases/cnpg-{bare}.yaml",
    ),
    "ARGOCD_VERSION": (
        "applications.argoproj.io",
        "https://raw.githubusercontent.com/argoproj/argo-cd/{v}/manifests/core-install.yaml",
    ),
    "CERT_MANAGER_VERSION": (
        "clusterissuers.cert-manager.io",
        "https://github.com/cert-manager/cert-manager/releases/download/{v}/cert-manager.yaml",
    ),
}
# A second CRD from the same pinned Argo CD manifest — not a second pin.
# Kept separate so a hand-edit that adds a field to schemas.json without
# re-deriving is visible as a second source the gate checks.
EXTRA_TARGETS = {
    "argoproj.io/v1alpha1/AppProject": (
        "ARGOCD_VERSION",
        "appprojects.argoproj.io",
        "https://raw.githubusercontent.com/argoproj/argo-cd/{v}/manifests/core-install.yaml",
    ),
}


def pins() -> dict[str, str]:
    src = INSTALL.read_text(encoding="utf-8")
    found = dict(re.findall(r'^(K3S_VERSION|CERT_MANAGER_VERSION|CNPG_VERSION|'
                            r'ARGOCD_VERSION|NATS_VERSION|NATS_BOX_VERSION)="([^"]+)"',
                            src, re.M))
    missing = [p for p in TARGETS if p not in found]
    if missing:
        raise SystemExit(f"install.sh does not declare {missing}")
    return found


def fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as r:  # noqa: S310 - pinned https
        return r.read().decode("utf-8")


def crd_doc(text: str, name: str) -> dict:
    for doc in yaml.safe_load_all(text):
        if doc and doc.get("kind") == "CustomResourceDefinition" \
                and doc.get("metadata", {}).get("name") == name:
            return doc
    raise SystemExit(f"release manifest does not carry CRD {name}")


def spec_props(crd: dict) -> dict:
    served = [v for v in crd["spec"]["versions"] if v.get("storage")]
    if len(served) != 1:
        raise SystemExit(f"{crd['metadata']['name']}: expected one storage version")
    return served[0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]


def model(node: dict) -> object:
    """A property-name graph: object -> {key: model}, array -> {"[]": model},
    a primitive -> True, and `*` for a node whose keys the CRD leaves open. A
    `"*"` KEY inside an object means the same for the keys it does not name
    (`additionalProperties` beside `properties`)."""
    if not isinstance(node, dict):
        return True
    if node.get("x-kubernetes-preserve-unknown-fields"):
        return "*"
    if node.get("type") == "array":
        return {"[]": model(node.get("items", {}))}
    props = node.get("properties")
    # `additionalProperties: false` CLOSES the object; only a truthy schema (or
    # a schema mapping) opens it. `is not None` would read `false` as open.
    open_keys = node.get("additionalProperties") not in (None, False)
    if props is None:
        return "*"
    built = {k: model(v) for k, v in props.items()}
    if open_keys:
        built["*"] = model(node.get("additionalProperties") or {})
    return built


def main() -> int:
    versions = pins()
    schemas: dict[str, object] = {}
    sources: dict[str, object] = {}
    for pin, (crd_name, url_tpl) in TARGETS.items():
        version = versions[pin]
        url = url_tpl.format(v=version, bare=version.lstrip("v"))
        crd = crd_doc(fetch(url), crd_name)
        api = f"{crd['spec']['group']}/{crd['spec']['versions'][0]['name']}"
        key = f"{api}/{crd['spec']['names']['kind']}"
        schemas[key] = model({"type": "object", "properties": spec_props(crd)})
        sources[key] = {"pin": pin, "version": version, "crdName": crd_name, "url": url}
        print(f"{key}: {len(schemas[key])} top-level fields from {version}")
    for key, (pin, crd_name, url_tpl) in EXTRA_TARGETS.items():
        version = versions[pin]
        url = url_tpl.format(v=version, bare=version.lstrip("v"))
        crd = crd_doc(fetch(url), crd_name)
        # key is already the canonical API/version/kind for this CRD
        schemas[key] = model({"type": "object", "properties": spec_props(crd)})
        sources[key] = {"pin": pin, "version": version, "crdName": crd_name, "url": url}
        print(f"{key}: {len(schemas[key])} top-level fields from {version} (extra)")
    payload = {
        "note": (
            "The property-name graph of each pinned CRD's spec, derived by "
            "tests/substrate-crd/regen.py from the same release URL "
            "templates/substrate/install.sh applies. Object -> {key: model}, "
            "array -> {'[]': model}, primitive or additionalProperties map -> "
            "True, arbitrary-key map -> '*'. NOT a type check and not "
            "exhaustive of Kubernetes semantics: it catches a field NAME the "
            "pinned CRD does not declare, which is exactly the class of defect "
            "CNPG's strict decoding refuses at apply time."
        ),
        "sources": sources,
        "schemas": schemas,
    }
    OUT.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
