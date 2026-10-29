#!/usr/bin/env bash

set -euo pipefail

EVENT="pull_request"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      EVENT="${2:?route.sh: --event needs a value}"
      shift 2
      ;;
    --event=*)
      EVENT="${1#--event=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    --*)
      echo "route.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

case "$EVENT" in
  pull_request) ;;
  *)
    echo "ROUTE=full"
    exit 0
    ;;
esac

if [ "$#" -eq 0 ]; then
  echo "ROUTE=full"
  exit 0
fi

is_tier=1
is_publish=1
is_docs=1

for p in "$@"; do
  case "$p" in
    templates/tier/*) ;;
    *) is_tier=0 ;;
  esac
  case "$p" in
    templates/publish/*) ;;
    *) is_publish=0 ;;
  esac
  case "$p" in
    *.md | *.markdown | *.txt | LICENSE* | NOTICE* | AUTHORS*) ;;
    *) is_docs=0 ;;
  esac
done

if [ "$is_tier" -eq 1 ]; then
  echo "ROUTE=tier"
elif [ "$is_publish" -eq 1 ]; then
  echo "ROUTE=publish"
elif [ "$is_docs" -eq 1 ]; then
  echo "ROUTE=docs"
else
  echo "ROUTE=full"
fi
exit 0
