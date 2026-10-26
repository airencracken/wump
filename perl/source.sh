#!/bin/bash
# Verify and unpack the pinned upstream release without changing system Perl.

wump_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "$wump_script_dir" ]; then
	printf '%s\n' 'Cannot locate the Perl build scripts.' >&2
	exit 1
fi
wump_version=
wump_url=
wump_size=
wump_sha512=
while read -r wump_key wump_value; do
	case "$wump_key" in
		version) wump_version=$wump_value ;;
		url) wump_url=$wump_value ;;
		size) wump_size=$wump_value ;;
		sha512) wump_sha512=$wump_value ;;
		''|'#'*) ;;
		*) printf 'Unknown upstream lock field: %s\n' "$wump_key" >&2; exit 1 ;;
	esac
done <"$wump_script_dir/upstream.lock"
if [ -z "$wump_version" ] || [ -z "$wump_url" ] || [ -z "$wump_size" ] || [ -z "$wump_sha512" ]; then
	printf '%s\n' 'Incomplete upstream lock file.' >&2
	exit 1
fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	printf 'usage: %s BUILD_DIRECTORY [ARCHIVE | --fetch]\n' "$0" >&2
	exit 1
fi
if ! mkdir -p -- "$1/perl"; then exit 1; fi
wump_build_dir=$(CDPATH= cd -- "$1/perl" && pwd)
if [ -z "$wump_build_dir" ]; then exit 1; fi
wump_source_dir=$wump_build_dir/perl-$wump_version
wump_archive=${2:-$wump_build_dir/perl-$wump_version.tar.xz}
wump_fetch=0
if [ "$wump_archive" = --fetch ]; then
	wump_fetch=1
	wump_archive=$wump_build_dir/perl-$wump_version.tar.xz
fi
if [ ! -f "$wump_archive" ]; then
	if [ "$wump_fetch" -eq 0 ]; then
		printf 'Perl source archive not found: %s\n' "$wump_archive" >&2
		printf '%s\n' 'Set PERL_TARBALL to the local 5.42.2 archive, or run make perl-fetch on a host with network access.' >&2
		exit 1
	fi
	wump_download=$(mktemp "$wump_build_dir/.download.XXXXXX")
	if [ -z "$wump_download" ]; then exit 1; fi
	if ! curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --output "$wump_download" "$wump_url"; then
		rm -f -- "$wump_download"
		printf '%s\n' 'Perl source download failed; existing sources were preserved.' >&2
		exit 1
	fi
	wump_archive=$wump_download
fi
if ! wump_actual_size=$(wc -c <"$wump_archive"); then exit 1; fi
if ! wump_digest=$(sha512sum <"$wump_archive"); then exit 1; fi
wump_digest=${wump_digest%% *}
if [ "$wump_actual_size" -ne "$wump_size" ] || [ "$wump_digest" != "$wump_sha512" ]; then
	printf 'Perl archive verification failed: %s\n' "$wump_archive" >&2
	if [ -n "${wump_download:-}" ]; then rm -f -- "$wump_download"; fi
	exit 1
fi
if [ -n "${wump_download:-}" ]; then
	wump_archive=$wump_build_dir/perl-$wump_version.tar.xz
	if ! mv -n -- "$wump_download" "$wump_archive"; then exit 1; fi
	if [ -e "$wump_download" ]; then
		rm -f -- "$wump_download"
		printf '%s\n' 'Archive destination appeared during download; retry after checking it.' >&2
		exit 1
	fi
fi
if [ -e "$wump_source_dir" ]; then
	if [ -f "$wump_source_dir/.wump-upstream" ] &&
		[ "$(cat "$wump_source_dir/.wump-upstream")" = "$wump_sha512" ]; then
		printf 'Verified existing source tree: %s\n' "$wump_source_dir"
		exit 0
	fi
	printf 'Refusing to overwrite existing source tree: %s\n' "$wump_source_dir" >&2
	exit 1
fi
wump_stage=$(mktemp -d "$wump_build_dir/.source.XXXXXX")
if [ -z "$wump_stage" ]; then exit 1; fi
if ! tar -xJf "$wump_archive" -C "$wump_stage" --no-same-owner; then
	rm -rf -- "$wump_stage"
	exit 1
fi
if [ ! -f "$wump_stage/perl-$wump_version/Configure" ]; then
	printf '%s\n' 'Verified archive did not contain the expected Perl source layout.' >&2
	rm -rf -- "$wump_stage"
	exit 1
fi
if ! printf '%s\n' "$wump_sha512" >"$wump_stage/perl-$wump_version/.wump-upstream"; then
	rm -rf -- "$wump_stage"
	exit 1
fi
if ! mv -T -n -- "$wump_stage/perl-$wump_version" "$wump_source_dir"; then
	rm -rf -- "$wump_stage"
	exit 1
fi
if [ -d "$wump_stage/perl-$wump_version" ]; then
	printf '%s\n' 'Source destination appeared during extraction; existing tree preserved.' >&2
	rm -rf -- "$wump_stage"
	exit 1
fi
if ! rmdir -- "$wump_stage"; then exit 1; fi
printf 'Verified and unpacked Perl %s: %s\n' "$wump_version" "$wump_source_dir"
