#!/bin/bash
wump_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "$wump_repo" ]; then exit 1; fi
wump_test=$(mktemp -d "${TMPDIR:-/tmp}/wump-build-flags.XXXXXX")
if [ -z "$wump_test" ]; then exit 1; fi
trap 'rm -rf -- "$wump_test"' EXIT
if ! cat >"$wump_test/cc" <<'SH'
#!/bin/bash
if ! printf 'compile\n' >>"$WUMP_BUILD_TRACE"; then exit 1; fi
wump_source=0
for wump_arg in "$@"; do
	case "$wump_arg" in *.c|*.S) wump_source=1 ;; esac
done
if [ "$wump_source" -ne 1 ]; then exit 2; fi
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ] && [ "$#" -gt 1 ]; then
		shift
		: >"$1"
		exit $?
	fi
	shift
done
exit 1
SH
then exit 1; fi
if ! cat >"$wump_test/ar" <<'SH'
#!/bin/bash
: >"$2"
SH
then exit 1; fi
if ! cp "$wump_test/cc" "$wump_test/another-cc"; then exit 1; fi
if ! chmod +x "$wump_test/cc" "$wump_test/another-cc" "$wump_test/ar"; then exit 1; fi
if ! : >"$wump_test/trace"; then exit 1; fi
wump_cc="$wump_test/cc"
wump_flags=-O1
wump_expected=0
for wump_step in first unchanged flags compiler; do
	case "$wump_step" in
		first) wump_expected=6 ;;
		flags) wump_flags='-O1 -fsanitize=memory'; wump_expected=12 ;;
		compiler) wump_cc="$wump_test/another-cc"; wump_expected=18 ;;
	esac
	if ! WUMP_BUILD_TRACE="$wump_test/trace" make -s -C "$wump_repo" BUILD="$wump_test/build" CC="$wump_cc" AR="$wump_test/ar" CFLAGS="$wump_flags" "$wump_test/build/libwump.a" >"$wump_test/output" 2>&1; then
		cat "$wump_test/output"
		exit 1
	fi
	wump_actual=$(wc -l <"$wump_test/trace")
	if [ "$wump_actual" -ne "$wump_expected" ]; then
		printf 'Build step %s compiled %s objects; expected cumulative count %s.\n' "$wump_step" "$wump_actual" "$wump_expected" >&2
		exit 1
	fi
done
if ! WUMP_BUILD_TRACE="$wump_test/trace" make -s -C "$wump_repo" BUILD="$wump_test/build" CC="$wump_cc" AR="$wump_test/ar" CFLAGS="$wump_flags" "$wump_test/build/test_context" >"$wump_test/output" 2>&1; then
	cat "$wump_test/output"
	exit 1
fi
printf '%s\n' 'ok - changing compiler or sanitizer flags rebuilds every runtime object; unchanged configuration reuses them'
