#!/bin/bash
# Build a private Perl with the context/op-sharing configuration the fork needs.

if [ "$#" -ne 1 ]; then
	printf 'usage: %s BUILD_DIRECTORY\n' "$0" >&2
	exit 1
fi
wump_sanitizer=${PERL_SANITIZER:-}
case "$wump_sanitizer" in
	''|address|thread|memory|undefined) ;;
	*) printf 'Unsupported PERL_SANITIZER: %s\n' "$wump_sanitizer" >&2; exit 1 ;;
esac
wump_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "$wump_script_dir" ]; then exit 1; fi
wump_version=$(awk '$1 == "version" {print $2}' "$wump_script_dir/upstream.lock")
if [ -z "$wump_version" ]; then exit 1; fi
wump_source_dir=$1/perl/perl-$wump_version
wump_runtime_override=
if [ -n "${PERL_RUNTIME_BUILD:-}" ]; then
	wump_runtime_override=$(CDPATH= cd -- "$PERL_RUNTIME_BUILD" && pwd)
	if [ -z "$wump_runtime_override" ]; then exit 1; fi
fi
if [ ! -f "$wump_source_dir/.wump-upstream" ]; then
	printf '%s\n' 'Run make perl-source before building the Perl fork.' >&2
	exit 1
fi
if ! cd -- "$wump_source_dir"; then exit 1; fi
wump_source_dir=$PWD
wump_runtime_build=$(CDPATH= cd -- ../.. && pwd)
if [ -z "$wump_runtime_build" ]; then exit 1; fi
if [ -n "$wump_runtime_override" ]; then wump_runtime_build=$wump_runtime_override; fi
if [ ! -f config.sh ]; then
	wump_configure=(-des -Dusemultiplicity -Duseithreads -Duse64bitall
		-Dprefix="$wump_source_dir/../install" -Dman1dir=none -Dman3dir=none)
	if [ -n "$wump_sanitizer" ]; then
		wump_configure+=("-Accflags=-fsanitize=$wump_sanitizer -fno-omit-frame-pointer -fno-optimize-sibling-calls"
			"-Aldflags=-fsanitize=$wump_sanitizer" "-Alddlflags=-shared -fsanitize=$wump_sanitizer" '-Doptimize=-O1')
	fi
	if [ "$wump_sanitizer" = memory ]; then
		wump_configure+=("-Dcc=${PERL_MSAN_CC:-clang}" "-Dld=${PERL_MSAN_CC:-clang}"
			'-Accflags=-fsanitize-memory-track-origins=2 -fPIE' '-Aldflags=-pie')
	fi
	if [ "$wump_sanitizer" = undefined ]; then
		wump_configure+=('-Accflags=-fno-sanitize-recover=all')
	fi
	if ! sh Configure "${wump_configure[@]}"; then
		printf '%s\n' 'Perl configuration failed; see config.log in the source tree.' >&2
		exit 1
	fi
fi
for wump_option in usemultiplicity useithreads; do
	if ! grep -q "^$wump_option='define'" config.sh; then
		printf 'Existing Perl configuration lacks %s; preserving it without rebuilding.\n' "$wump_option" >&2
		exit 1
	fi
done
for wump_flag in ccflags ldflags lddlflags; do
	for wump_configured_sanitizer in address thread memory undefined; do
		if grep -q "^$wump_flag='.*-fsanitize=$wump_configured_sanitizer" config.sh &&
			[ "$wump_sanitizer" != "$wump_configured_sanitizer" ]; then
			printf 'Existing Perl configuration uses %s; select the matching PERL_SANITIZER or a separate build directory.\n' "$wump_configured_sanitizer" >&2
			exit 1
		fi
	done
	if [ -n "$wump_sanitizer" ] && ! grep -q "^$wump_flag='.*-fsanitize=$wump_sanitizer" config.sh; then
		printf 'Existing Perl configuration lacks %s in %s; use a separate build directory.\n' "$wump_sanitizer" "$wump_flag" >&2
		exit 1
	fi
done
if [ "$wump_sanitizer" = memory ]; then
	if ! grep -q "^ccflags='.*-fsanitize-memory-track-origins=2" config.sh; then
		printf '%s\n' 'Existing MSan configuration lacks origin tracking; use a separate build directory.' >&2
		exit 1
	fi
	if ! grep -q "^ldflags='.*-pie" config.sh; then
		printf '%s\n' 'Existing MSan configuration lacks PIE linking; use a separate build directory.' >&2
		exit 1
	fi
fi
if [ -n "$wump_sanitizer" ] && ! grep -q "^lddlflags='.*-shared" config.sh; then
	printf '%s\n' 'Existing sanitizer configuration lacks shared-library link flags; use a separate build directory.' >&2
	exit 1
fi
if [ "$wump_sanitizer" = undefined ] && ! grep -q "^ccflags='.*-fno-sanitize-recover=all" config.sh; then
	printf '%s\n' 'Existing UBSan configuration allows recovery; use a separate build directory.' >&2
	exit 1
fi
if ! perl "$wump_script_dir/apply.pl" "$wump_source_dir"; then exit 1; fi
wump_jobs=${PERL_JOBS:-4}
if [[ ! "$wump_jobs" =~ ^[1-9][0-9]*$ ]]; then
	printf '%s\n' 'PERL_JOBS must be a positive integer.' >&2
	exit 1
fi
wump_runtime_objects=
for wump_object in stack sched chan io error ctx_x86_64; do
	if [ ! -f "$wump_runtime_build/$wump_object.o" ]; then
		printf 'Missing runtime object: %s\n' "$wump_runtime_build/$wump_object.o" >&2
		exit 1
	fi
	wump_runtime_objects="$wump_runtime_objects $wump_runtime_build/$wump_object.o"
done
wump_runtime_config=$(printf 'ARCHOBJS =%s\ninclude %s/deps.mk\n' "$wump_runtime_objects" "$wump_script_dir")
if [ ! -f wump_runtime.mk ] || [ "$(cat wump_runtime.mk)" != "$wump_runtime_config" ]; then
	if ! printf '%s\n' "$wump_runtime_config" >wump_runtime.mk; then exit 1; fi
fi
for wump_makefile in Makefile makefile; do
	if [ -f "$wump_makefile" ] && ! grep -q '^include wump_runtime.mk$' "$wump_makefile"; then
		if ! chmod u+w "$wump_makefile"; then exit 1; fi
		if ! printf '\ninclude wump_runtime.mk\n' >>"$wump_makefile"; then exit 1; fi
	fi
done
if ! make -j"$wump_jobs"; then
	printf '%s\n' 'Perl build failed; the source and build outputs were preserved.' >&2
	exit 1
fi
if ! ./perl -Ilib -MConfig -e '
	die "wrong Perl version\n" unless $^V eq v5.42.2;
	die "MULTIPLICITY is required\n" unless $Config{usemultiplicity} eq "define";
	die "op-sharing infrastructure is required\n" unless $Config{useithreads} eq "define";
	print "Private Perl $^V is ready (MULTIPLICITY and USE_ITHREADS).\n";
'; then exit 1; fi
