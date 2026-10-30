#!/bin/bash
if [ "$#" -lt 4 ]; then
	printf 'usage: %s BUILD all|TOOL ITERATIONS SLOTS [COMMAND [ARG...]]\n' "$0" >&2
	exit 1
fi
wump_build=$1
wump_tools=$2
wump_iterations=$3
wump_slots=$4
case "$wump_tools" in
	all) wump_tools='memcheck helgrind drd massif callgrind cachegrind dhat bbv lackey' ;;
	memcheck|helgrind|drd|massif|callgrind|cachegrind|dhat|bbv|lackey) ;;
	*) printf 'Unknown Valgrind tool: %s\n' "$2" >&2; exit 1 ;;
esac
if [[ ! "$wump_iterations" =~ ^[1-9][0-9]*$ ]] || [[ ! "$wump_slots" =~ ^[1-9][0-9]*$ ]]; then
	printf '%s\n' 'Valgrind iterations and execution slots must be positive integers.' >&2
	exit 1
fi
if [ "$#" -gt 4 ]; then
	shift 4
	wump_command=("$@")
else
	wump_command=("$wump_build/bench" "$wump_iterations" "$wump_slots")
fi
if ! mkdir -p -- "$wump_build/reports"; then exit 1; fi
wump_reports=$(mktemp -d "$wump_build/reports/run.XXXXXX")
if [ -z "$wump_reports" ]; then exit 1; fi
printf 'Valgrind reports: %s\n' "$wump_reports"
if ! printf 'tool\texit_status\n' >"$wump_reports/status.tsv"; then exit 1; fi
wump_failed=0
for wump_tool in $wump_tools; do
	wump_options=("--log-file=$wump_reports/$wump_tool.%p.log" --error-exitcode=99)
	wump_native_tool=$wump_tool
	case "$wump_tool" in
		memcheck) wump_options+=(--leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --track-origins=yes) ;;
		massif) wump_options+=("--massif-out-file=$wump_reports/massif.%p.out" --stacks=yes) ;;
		callgrind) wump_options+=("--callgrind-out-file=$wump_reports/callgrind.%p.out" --collect-jumps=yes) ;;
		cachegrind) wump_options+=("--cachegrind-out-file=$wump_reports/cachegrind.%p.out" --branch-sim=yes) ;;
		dhat) wump_options+=("--dhat-out-file=$wump_reports/dhat.%p.json") ;;
		bbv) wump_native_tool=exp-bbv; wump_options+=("--bb-out-file=$wump_reports/bbv.%p.out" "--pc-out-file=$wump_reports/bbv-pc.%p.out") ;;
		lackey) wump_options+=(--basic-counts=yes --detailed-counts=yes) ;;
	esac
	PERL_DESTRUCT_LEVEL=2 WUMPPROCS=$wump_slots timeout "${VALGRIND_TIMEOUT:-300}s" valgrind "--tool=$wump_native_tool" "${wump_options[@]}" \
		"${wump_command[@]}" >"$wump_reports/$wump_tool.csv" 2>"$wump_reports/$wump_tool.stderr"
	wump_status=$?
	if ! printf '%s\t%s\n' "$wump_tool" "$wump_status" >>"$wump_reports/status.tsv"; then exit 1; fi
	if [ "$wump_status" -ne 0 ]; then
		printf 'FAIL - %s exited %s; see %s\n' "$wump_tool" "$wump_status" "$wump_reports"
		wump_failed=1
	else
		printf 'ok - %s completed the workload on %s slots\n' "$wump_tool" "$wump_slots"
	fi
done
exit "$wump_failed"
