#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: $0 VERSION}"

if [ "${#version}" -gt 128 ]; then
	echo "version must be 128 characters or fewer" >&2
	exit 64
fi

case "${version}" in
[A-Za-z0-9_]*) ;;
*)
	echo "version must start with an ASCII letter, digit, or underscore" >&2
	exit 64
	;;
esac

case "${version}" in
*[!A-Za-z0-9_.-]*)
	echo "version may only contain ASCII letters, digits, underscores, periods, and hyphens" >&2
	exit 64
	;;
esac

printf '%s\n' "${version}"
