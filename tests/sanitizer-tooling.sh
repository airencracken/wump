#!/bin/bash
# Exercise report validation without depending on a working sanitizer runtime.
wump_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "$wump_repo" ]; then exit 1; fi
wump_test=$(mktemp -d "${TMPDIR:-/tmp}/wump-sanitizer-tooling.XXXXXX")
if [ -z "$wump_test" ]; then exit 1; fi
trap 'rm -rf -- "$wump_test"' EXIT
if ! mkdir "$wump_test/build with spaces"; then exit 1; fi
if ! cat >"$wump_test/build with spaces/msan_control" <<'SH'
#!/bin/bash
if [ "$MSAN_OPTIONS" != halt_on_error=1:exit_code=88 ]; then exit 9; fi
if [ "$#" -eq 0 ]; then
	if [ "$WUMP_CONTROL_MODE" = preflight ]; then exit 88; fi
	exit 0
fi
case "$WUMP_CONTROL_MODE" in
	clean) exit 0 ;;
	timeout) exit 124 ;;
	crash) exit 139 ;;
	report) printf '%s\n' 'unrelated sanitizer startup failure'; exit 88 ;;
esac
printf '%s\n' 'WARNING: MemorySanitizer: use-of-uninitialized-value'
if [ "$WUMP_CONTROL_MODE" != origins ]; then
	printf '%s\n' 'Uninitialized value was created by a heap allocation'
fi
if [ "$WUMP_CONTROL_MODE" = status ]; then exit 1; fi
exit 88
SH
then exit 1; fi
if ! chmod +x "$wump_test/build with spaces/msan_control"; then exit 1; fi
if ! WUMP_CONTROL_MODE=valid bash "$wump_repo/tests/sanitizers.sh" "$wump_test/build with spaces" msan >"$wump_test/output" 2>&1; then
	cat "$wump_test/output"
	printf '%s\n' 'Valid MSan control reports were rejected.' >&2
	exit 1
fi
for wump_mode in preflight clean timeout crash report status origins; do
	if WUMP_CONTROL_MODE=$wump_mode bash "$wump_repo/tests/sanitizers.sh" "$wump_test/build with spaces" msan >"$wump_test/output" 2>&1; then
		printf 'MSan tooling accepted invalid control mode: %s\n' "$wump_mode" >&2
		exit 1
	fi
done
printf '%s\n' 'ok - MSan controls require a clean preflight, exact failure status, diagnostic and origins; crashes and timeouts fail'

if ! cat >"$wump_test/build with spaces/ub_control" <<'SH'
#!/bin/bash
if [ "$UBSAN_OPTIONS" != halt_on_error=1:print_stacktrace=1:exitcode=89 ]; then exit 9; fi
if [ "$#" -eq 0 ]; then
	if [ "$WUMP_CONTROL_MODE" = preflight ]; then exit 89; fi
	exit 0
fi
case "$WUMP_CONTROL_MODE" in
	clean) exit 0 ;;
	timeout) exit 124 ;;
	crash) exit 139 ;;
	report) printf '%s\n' 'unrelated startup failure'; exit 89 ;;
esac
case "$1" in
	overflow) printf '%s\n' 'runtime error: signed integer overflow' ;;
	bounds) printf '%s\n' 'runtime error: index 2 out of bounds' ;;
	float) printf '%s\n' 'runtime error: division by zero' ;;
	conversion) printf '%s\n' 'runtime error: implicit conversion' ;;
	cfi) printf '%s\n' 'runtime error: control flow integrity check' ;;
	*) exit 3 ;;
esac
if [ "$WUMP_CONTROL_MODE" = status ]; then exit 1; fi
exit 89
SH
then exit 1; fi
if ! chmod +x "$wump_test/build with spaces/ub_control"; then exit 1; fi
for wump_kind in ubsan ubsan-clang cfi; do
	if ! WUMP_CONTROL_MODE=valid bash "$wump_repo/tests/sanitizers.sh" "$wump_test/build with spaces" "$wump_kind" >"$wump_test/output" 2>&1; then
		cat "$wump_test/output"
		exit 1
	fi
	for wump_mode in preflight clean timeout crash report status; do
		if WUMP_CONTROL_MODE=$wump_mode bash "$wump_repo/tests/sanitizers.sh" "$wump_test/build with spaces" "$wump_kind" >"$wump_test/output" 2>&1; then
			printf '%s control validation accepted invalid mode %s.\n' "$wump_kind" "$wump_mode" >&2
			exit 1
		fi
	done
done
printf '%s\n' 'ok - UBSan and CFI controls require the expected diagnostics and failure codes after a clean preflight'

if ! mkdir "$wump_test/bin"; then exit 1; fi
if ! cat >"$wump_test/bin/valgrind" <<'SH'
#!/bin/bash
case "$1" in --tool=*) wump_tool=${1#--tool=} ;; *) exit 3 ;; esac
if ! printf '%s\n' "$wump_tool" >>"$WUMP_VG_TRACE"; then exit 1; fi
if [ "$WUMP_VG_MODE" = failure ] && [ "$wump_tool" = helgrind ]; then exit 99; fi
if [ "$WUMP_VG_MODE" = timeout ] && [ "$wump_tool" = drd ]; then exit 124; fi
while [ "$#" -gt 0 ] && [[ "$1" == --* ]]; do shift; done
"$@"
SH
then exit 1; fi
if ! cat >"$wump_test/build with spaces/bench" <<'SH'
#!/bin/bash
if [ "$WUMPPROCS" != 4 ] || [ "$PERL_DESTRUCT_LEVEL" != 2 ] || [ "$#" -ne 2 ]; then exit 2; fi
if [ "$1" = 10 ] && [ "$2" = 4 ]; then exit 0; fi
if [ "$1" = 'custom argument' ] && [ "$2" = '-literal' ]; then exit 0; fi
exit 3
SH
then exit 1; fi
if ! chmod +x "$wump_test/build with spaces/bench"; then exit 1; fi
if ! chmod +x "$wump_test/bin/valgrind"; then exit 1; fi
for wump_mode in valid failure timeout; do
	if ! : >"$wump_test/trace"; then exit 1; fi
	PATH="$wump_test/bin:$PATH" WUMP_VG_TRACE="$wump_test/trace" WUMP_VG_MODE=$wump_mode \
		bash "$wump_repo/tests/valgrind-tools.sh" "$wump_test/build with spaces" all 10 4 >"$wump_test/output" 2>&1
	wump_status=$?
	if [ "$wump_mode" = valid ] && [ "$wump_status" -ne 0 ]; then cat "$wump_test/output"; exit 1; fi
	if [ "$wump_mode" != valid ] && [ "$wump_status" -ne 1 ]; then cat "$wump_test/output"; exit 1; fi
	if ! printf '%s\n' memcheck helgrind drd massif callgrind cachegrind dhat exp-bbv lackey >"$wump_test/expected"; then exit 1; fi
	if ! cmp "$wump_test/trace" "$wump_test/expected"; then
		printf '%s\n' 'Valgrind runner missed tools or stopped after a failed tool.' >&2
		exit 1
	fi
done
if ! PATH="$wump_test/bin:$PATH" WUMP_VG_TRACE="$wump_test/trace" WUMP_VG_MODE=valid \
	bash "$wump_repo/tests/valgrind-tools.sh" "$wump_test/build with spaces" all 10 4 "$wump_test/build with spaces/bench" 'custom argument' -literal >"$wump_test/output" 2>&1; then
	cat "$wump_test/output"
	exit 1
fi
if bash "$wump_repo/tests/valgrind-tools.sh" "$wump_test/build with spaces" unknown 10 4 >"$wump_test/output" 2>&1; then exit 1; fi
if bash "$wump_repo/tests/valgrind-tools.sh" "$wump_test/build with spaces" all 0 4 >"$wump_test/output" 2>&1; then exit 1; fi
printf '%s\n' 'ok - every Valgrind tool runs with paths containing spaces; errors and timeouts fail the run without skipping later tools'
