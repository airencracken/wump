#!/bin/bash
if [ "$#" -ne 2 ]; then
	printf 'usage: %s BUILD asan|lsan|msan|ubsan|ubsan-clang|cfi\n' "$0" >&2
	exit 1
fi
wump_build=$1
case "$2" in
	ubsan|ubsan-clang|cfi)
		wump_log="$wump_build/control-$2-clean.log"
		UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=89 \
			timeout 60s "$wump_build/ub_control" >"$wump_log" 2>&1
		wump_status=$?
		if [ "$wump_status" -ne 0 ]; then
			cat "$wump_log"
			printf '%s clean-process preflight failed (exit %s).\n' "$2" "$wump_status" >&2
			exit 1
		fi
		if [ "$2" = cfi ]; then wump_kinds=cfi; else wump_kinds='overflow bounds float'; fi
		if [ "$2" = ubsan-clang ]; then wump_kinds="$wump_kinds conversion"; fi
		for wump_kind in $wump_kinds; do
			wump_log="$wump_build/control-$2-$wump_kind.log"
			UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=89 \
				timeout 30s "$wump_build/ub_control" "$wump_kind" >"$wump_log" 2>&1
			wump_status=$?
			case "$wump_kind" in
				overflow) wump_report='signed integer overflow' ;;
				bounds) wump_report='index 2 out of bounds' ;;
				float) wump_report='division by zero' ;;
				cfi) wump_report='control flow integrity check' ;;
				conversion) wump_report='implicit conversion' ;;
			esac
			if [ "$wump_status" -ne 89 ] || ! grep -qF "$wump_report" "$wump_log"; then
				cat "$wump_log"
				printf 'Expected %s control report for %s, got exit %s\n' "$2" "$wump_kind" "$wump_status" >&2
				exit 1
			fi
			printf 'ok - %s detects deliberate %s on a coroutine stack\n' "$2" "$wump_kind"
		done
		;;
	msan)
		wump_log="$wump_build/control-msan-clean.log"
		MSAN_OPTIONS=halt_on_error=1:exit_code=88 \
			timeout 60s "$wump_build/msan_control" >"$wump_log" 2>&1
		wump_status=$?
		if [ "$wump_status" -ne 0 ]; then
			cat "$wump_log"
			printf 'MSan clean-process preflight failed (exit %s); uninitialized-read detection is not validated.\n' "$wump_status" >&2
			exit 1
		fi
		for wump_kind in heap stack channel; do
			wump_log="$wump_build/control-msan-$wump_kind.log"
			MSAN_OPTIONS=halt_on_error=1:exit_code=88 \
				timeout 30s "$wump_build/msan_control" "$wump_kind" >"$wump_log" 2>&1
			wump_status=$?
			if [ "$wump_status" -ne 88 ] || ! grep -qF 'MemorySanitizer: use-of-uninitialized-value' "$wump_log"; then
				cat "$wump_log"
				printf 'Expected an MSan uninitialized-read report for %s, got exit %s\n' "$wump_kind" "$wump_status" >&2
				exit 1
			fi
			if ! grep -qF 'Uninitialized value was created by' "$wump_log"; then
				cat "$wump_log"
				printf 'MSan origin tracking is missing for %s\n' "$wump_kind" >&2
				exit 1
			fi
			printf 'ok - MSan detects deliberate %s uninitialized use with origins\n' "$wump_kind"
		done
		;;
	asan)
		for wump_kind in heap stack return compare subtract; do
			wump_log="$wump_build/control-$wump_kind.log"
			ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1:detect_invalid_pointer_pairs=2:halt_on_error=1:exitcode=86 \
				timeout 30s "$wump_build/sanitizer_control" "$wump_kind" >"$wump_log" 2>&1
			wump_status=$?
			case "$wump_kind" in
				heap) wump_report='AddressSanitizer: heap-use-after-free' ;;
				stack) wump_report='AddressSanitizer: stack-buffer-overflow' ;;
				return) wump_report='AddressSanitizer: stack-use-after-return' ;;
				compare|subtract) wump_report='AddressSanitizer: invalid-pointer-pair' ;;
			esac
			if [ "$wump_status" -ne 86 ] || ! grep -qF "$wump_report" "$wump_log"; then
				cat "$wump_log"
				printf 'Expected %s, got exit %s\n' "$wump_report" "$wump_status" >&2
				exit 1
			fi
			printf 'ok - ASan detects deliberate %s error on a coroutine stack\n' "$wump_kind"
		done
		;;
	lsan)
		wump_log="$wump_build/control-lsan-clean.log"
		ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 LSAN_OPTIONS=exitcode=87 \
			timeout 60s "$wump_build/sanitizer_control" >"$wump_log" 2>&1
		wump_status=$?
		if [ "$wump_status" -ne 0 ]; then
			cat "$wump_log"
			printf 'LSan clean-process preflight failed (exit %s); leak detection is not validated.\n' "$wump_status" >&2
			exit 1
		fi
		wump_log="$wump_build/control-leak.log"
		ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 LSAN_OPTIONS=exitcode=87 \
			timeout 30s "$wump_build/sanitizer_control" leak >"$wump_log" 2>&1
		wump_status=$?
		if [ "$wump_status" -ne 87 ] || ! grep -qF 'LeakSanitizer: detected memory leaks' "$wump_log"; then
			cat "$wump_log"
			printf 'Expected a deliberate LSan leak report, got exit %s\n' "$wump_status" >&2
			exit 1
		fi
		printf '%s\n' 'ok - LSan detects a deliberate allocation leaked by a completed coroutine'
		;;
	*) printf 'Unknown sanitizer: %s\n' "$2" >&2; exit 1 ;;
esac
