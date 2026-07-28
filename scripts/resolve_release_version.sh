#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 STABLE_VERSION" >&2
  exit 64
fi

version="${1#v}"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "version must be a stable MAJOR.MINOR.PATCH release without leading zeroes" >&2
  exit 65
fi

printf '%s\n' "$version"
