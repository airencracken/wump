#!/bin/bash
# Source acquisition must fail before touching an existing tree on bad input.

wump_repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ -z "$wump_repo" ]; then exit 1; fi
wump_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/wump-perl-source.XXXXXX")
if [ -z "$wump_test_dir" ]; then exit 1; fi
trap 'rm -rf -- "$wump_test_dir"' EXIT
wump_build_dir=$wump_test_dir/build\ with\ spaces
if ! mkdir -p "$wump_build_dir/perl/perl-5.42.2"; then exit 1; fi
if ! printf '%s\n' 'preserve this tree' >"$wump_build_dir/perl/perl-5.42.2/sentinel"; then exit 1; fi
if bash "$wump_repo/perl/source.sh" "$wump_build_dir" "$wump_test_dir/missing.tar.xz" >"$wump_test_dir/output" 2>&1; then
	printf '%s\n' 'Missing source archive unexpectedly succeeded.' >&2
	exit 1
fi
if ! grep -q 'source archive not found' "$wump_test_dir/output"; then cat "$wump_test_dir/output"; exit 1; fi
if ! printf '%s\n' 'this is not the pinned Perl release' >"$wump_test_dir/bad archive.tar.xz"; then exit 1; fi
if bash "$wump_repo/perl/source.sh" "$wump_build_dir" "$wump_test_dir/bad archive.tar.xz" >"$wump_test_dir/output" 2>&1; then
	printf '%s\n' 'Invalid archive unexpectedly succeeded.' >&2
	exit 1
fi
if ! grep -q 'verification failed' "$wump_test_dir/output"; then cat "$wump_test_dir/output"; exit 1; fi
if [ "$(cat "$wump_build_dir/perl/perl-5.42.2/sentinel")" != 'preserve this tree' ]; then
	printf '%s\n' 'Existing source tree was modified.' >&2
	exit 1
fi
if [ -f "$wump_build_dir/perl/perl-5.42.2/.wump-upstream" ]; then
	printf '%s\n' 'Invalid source was marked as verified.' >&2
	exit 1
fi
if bash "$wump_repo/perl/build.sh" "$wump_build_dir" >"$wump_test_dir/output" 2>&1; then
	printf '%s\n' 'Build accepted an unverified source tree.' >&2
	exit 1
fi
printf '%s\n' 'ok - missing and corrupt Perl sources preserve existing trees and cannot be built'

if ! mkdir "$wump_test_dir/bin"; then exit 1; fi
if ! cat >"$wump_test_dir/bin/curl" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ]; do
	if [ "$1" = --output ]; then
		shift
		printf '%s\n' 'incomplete or invalid download' >"$1"
		break
	fi
	shift
done
exit "${WUMP_TEST_CURL_STATUS:-0}"
EOF
then exit 1; fi
if ! chmod +x "$wump_test_dir/bin/curl"; then exit 1; fi
for wump_fetch_status in 0 22; do
	if PATH="$wump_test_dir/bin:$PATH" WUMP_TEST_CURL_STATUS=$wump_fetch_status \
		bash "$wump_repo/perl/source.sh" "$wump_build_dir" --fetch >"$wump_test_dir/output" 2>&1; then
		printf '%s\n' 'Invalid/failed download unexpectedly succeeded.' >&2
		exit 1
	fi
	if [ -e "$wump_build_dir/perl/perl-5.42.2.tar.xz" ]; then
		printf '%s\n' 'Invalid/failed download was cached as a valid archive.' >&2
		exit 1
	fi
	shopt -s nullglob
	wump_leftovers=("$wump_build_dir/perl/".download.*)
	if [ "${#wump_leftovers[@]}" -ne 0 ]; then
		printf '%s\n' 'Failed download temporary file was not cleaned up.' >&2
		exit 1
	fi
done
printf '%s\n' 'ok - failed downloads and invalid responses are rejected without leaving cached archives'
