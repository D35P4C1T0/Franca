#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

version=${1:-}
if [[ -z $version && ${GITHUB_REF:-} == refs/tags/v* ]]; then
    version=${GITHUB_REF#refs/tags/}
fi
if [[ -z $version ]]; then
    version=$(sed -n 's/^VERSION[[:space:]]*:=[[:space:]]*//p' Makefile)
fi
version=${version#v}
if [[ ! $version =~ ^[0-9][0-9A-Za-z._+-]*$ ]]; then
    printf 'Invalid package version: %s\n' "$version" >&2
    exit 1
fi
printf '%s\n' "$version"
