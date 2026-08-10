#!/usr/bin/env bash
# Resolves the R2 configuration that publishing needs. Sourced, not executed, by
# publish-cdn.sh and by release.sh's preflight, so that the check and the upload
# cannot disagree about where the bucket is or where the keys came from.
#
# The endpoint, bucket and prefix are configuration rather than credentials: they
# name a public bucket that consumers already download from, and having them
# here is what makes a release one command instead of a lookup in someone's
# shell history.
#
# The keys are credentials and are never stored here. CI passes them in as
# environment variables; on a laptop they are read out of an AWS profile, which
# keeps them out of the terminal and out of the process list. Set
# R2_AWS_PROFILE to read a different one.

: "${R2_ENDPOINT_URL:=https://285101663c2358c357d1505333184643.r2.cloudflarestorage.com}"
: "${R2_BUCKET:=downloads}"
: "${R2_PREFIX:=bundle-vm}"

if [ -z "${R2_ACCESS_KEY_ID:-}" ] && command -v aws >/dev/null 2>&1; then
	r2_profile="${R2_AWS_PROFILE:-r2}"
	R2_ACCESS_KEY_ID="$(aws configure get aws_access_key_id --profile "${r2_profile}" 2>/dev/null || true)"
	R2_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key --profile "${r2_profile}" 2>/dev/null || true)"
	unset r2_profile
fi

export R2_ENDPOINT_URL R2_BUCKET R2_PREFIX
export R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
export R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
