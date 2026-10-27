#!/bin/bash
if [ "$#" -ne 2 ]; then
	printf 'usage: %s BUILD asan|lsan\n' "$0" >&2
	exit 1
fi
wump_build=$1
case "$2" in
	asan)
		for wump_kind in heap stack return; do
			wump_log="$wump_build/control-$wump_kind.log"
			ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1:halt_on_error=1:exitcode=86 \
				timeout 30s "$wump_build/sanitizer_control" "$wump_kind" >"$wump_log" 2>&1
			wump_status=$?
			case "$wump_kind" in
				heap) wump_report='AddressSanitizer: heap-use-after-free' ;;
				stack) wump_report='AddressSanitizer: stack-buffer-overflow' ;;
				return) wump_report='AddressSanitizer: stack-use-after-return' ;;
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
