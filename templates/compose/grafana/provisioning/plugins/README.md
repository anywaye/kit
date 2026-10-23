# Grafana looks here for plugin provisioning on every boot.

Grafana logs `Failed to read plugin provisioning files from directory ... no such
file or directory` at ERROR level when this directory does not exist. It is
harmless — the stack works — and it is still an ERROR on first load of a
dashboard we told a self-hoster was provisioned and working, which is a poor
first impression and a bad thing to grep for at 2am.

This file exists so the directory exists. Git does not track empty directories,
so the README is the mechanism rather than a workaround.

anywaye ships no plugin provisioning of its own, and needs none.
