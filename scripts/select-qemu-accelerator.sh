#!/usr/bin/env bash
set -euo pipefail

case "${QEMU_ACCELERATOR:-auto}" in
auto | "") ;;
kvm | hvf | none)
	printf '%s\n' "${QEMU_ACCELERATOR}"
	exit 0
	;;
*)
	echo "QEMU_ACCELERATOR must be auto, kvm, hvf, or none" >&2
	exit 64
	;;
esac

if [ "$(uname -s)" = "Darwin" ]; then
	printf '%s\n' hvf
elif [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	printf '%s\n' kvm
else
	printf '%s\n' none
fi
