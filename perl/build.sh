#!/bin/bash
# Build a private Perl with the context/op-sharing configuration the fork needs.

if [ "$#" -ne 1 ]; then
	printf 'usage: %s BUILD_DIRECTORY\n' "$0" >&2
	exit 1
fi
wump_version=$(awk '$1 == "version" {print $2}' "$(dirname -- "$0")/upstream.lock")
if [ -z "$wump_version" ]; then exit 1; fi
wump_source_dir=$1/perl/perl-$wump_version
if [ ! -f "$wump_source_dir/.wump-upstream" ]; then
	printf '%s\n' 'Run make perl-source before building the Perl fork.' >&2
	exit 1
fi
if ! cd -- "$wump_source_dir"; then exit 1; fi
wump_source_dir=$PWD
if [ ! -f config.sh ]; then
	if ! sh Configure -des -Dusemultiplicity -Duseithreads -Duse64bitall \
		-Dprefix="$wump_source_dir/../install" -Dman1dir=none -Dman3dir=none; then
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
wump_jobs=${PERL_JOBS:-4}
if [[ ! "$wump_jobs" =~ ^[1-9][0-9]*$ ]]; then
	printf '%s\n' 'PERL_JOBS must be a positive integer.' >&2
	exit 1
fi
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
