CC = cc
AR = ar
BUILD = build
ITERATIONS = 100000
PERL_TARBALL = $(BUILD)/perl/perl-5.42.2.tar.xz
CPPFLAGS = -Iruntime/include -Iruntime/src
CFLAGS = -O2 -g -std=c11 -Wall -Wextra -Werror -pthread
LDFLAGS = -pthread
LDLIBS = -lm
MSAN_CC = clang
MSAN_CFLAGS = -O1 -fsanitize=memory -fsanitize-memory-track-origins=2 -fno-omit-frame-pointer -fno-optimize-sibling-calls -fPIE
MSAN_LDFLAGS = -fsanitize=memory -fsanitize-memory-track-origins=2 -pie
UBSAN_CHECKS = undefined,float-divide-by-zero
UBSAN_CONTROL = ubsan
CLANG = clang
CLANG_CXX = clang++
CLANG_AR = llvm-ar
CFI_CFLAGS = -O1 -flto -fvisibility=hidden -fsanitize=cfi -fno-sanitize-trap=cfi -fno-sanitize-recover=all
CFI_LDFLAGS = -flto -fuse-ld=lld -fsanitize=cfi -fno-sanitize-trap=cfi -fno-sanitize-recover=all
VALGRIND_ITERATIONS = 100
VALGRIND_SLOTS = 4
TEST_TIMEOUT = 60
TEST_LONG_TIMEOUT = 90
TEST_FAILURE_TIMEOUT = 30
PERL_FULL_TEST_JOBS = 4
PERL_FULL_TEST_TIMEOUT = 1800
PERL_PERF_BASELINE = bench/perl-dispatch-after.jsonl
PERL_PERF_CURRENT = $(BUILD)/perl-baseline-current.jsonl
PERL_PERF_MAX_REGRESSION = 10
SANITIZER_TEST_ARGS = CPPFLAGS='$(CPPFLAGS) -DWUMP_TEST_CASE_TIMEOUT=120' TEST_TIMEOUT=300 TEST_LONG_TIMEOUT=300 TEST_FAILURE_TIMEOUT=300
PERL_SUITES = entry ordinary active waitgroup preempt tasks parallel xs-parallel encode-parallel bytes-parallel native-integration regex-parallel regex local elements pocket pocket-deparse separators hooks locks shared keys reads read-claims scalar-writes operands stack-loads lvalue-loads reference-loads scalar-references materialization iteration memory publication hidden-roots

RUNTIME = stack sched chan io error
OBJECTS = $(addprefix $(BUILD)/,$(addsuffix .o,$(RUNTIME))) $(BUILD)/ctx_x86_64.o
RUNTIME_PROGRAMS = hello select echo blocking test_runtime test_select test_io test_syscall test_context test_syscall_failures test_failures test_io_failures bench sanitizer_control msan_control ub_control tsan_race
shell_quote = '$(subst ','"'"',$(1))'
WRAPPED = pthread_mutex_init pthread_cond_init pthread_condattr_init pthread_condattr_setclock posix_memalign mmap munmap mprotect pthread_create pthread_join malloc calloc realloc
IO_WRAPPED = calloc realloc pthread_mutex_init pthread_create epoll_create1 eventfd epoll_ctl epoll_wait fcntl poll __poll_chk read __read_chk write close accept4 connect getsockopt getpeername
SYSCALL_WRAPPED = calloc pthread_cond_init pthread_cond_destroy pthread_cond_broadcast pthread_create pthread_join

.PHONY: all test stress ubsan asan lsan asan-control lsan-control tsan tsan-control memcheck bench bench-compare clean perl-source perl-fetch perl-build perl-source-test perl-test perl-asan perl-lsan perl-leak-test perl-task-context-test perl-task-context-tsan perl-example perl-regex-example perl-local-example perl-elements-example perl-pocket-example perl-separators-example perl-safety-example perl-publication-example perl-refcount-test perl-refcount-tsan perl-memcheck perl-upstream-test
all: $(BUILD)/libwump.a $(BUILD)/hello $(BUILD)/select $(BUILD)/echo $(BUILD)/blocking

.PHONY: perl-mojo-test perl-mojo-example perl-mojo-memcheck
.PHONY: perl-mojo-cpu-test perl-mojo-cpu-bench
perl-mojo-cpu-test: perl-build
	timeout 180s perl tests/perl/mojo-bench.t '$(abspath $(BUILD))/perl/perl-5.42.2/perl'

perl-mojo-cpu-bench: perl-build
	perl bench/mojo-cpu.pl '$(abspath $(BUILD))/perl/perl-5.42.2/perl'

STOCK_PERL = $(BUILD)/stock/perl/perl-5.42.2/perl
.PHONY: perl-baseline-bench perl-baseline-test perl-perf-test perl-perf-check perl-perf-check-test
perl-baseline-bench: perl-build
	timeout 300s perl bench/perl-baseline.pl '$(abspath $(BUILD))/perl/perl-5.42.2/perl' '$(abspath $(STOCK_PERL))'

perl-baseline-test: perl-build
	timeout 90s perl tests/perl/baseline-bench.t '$(abspath $(BUILD))/perl/perl-5.42.2/perl' '$(abspath $(STOCK_PERL))'

perl-perf-check:
	perl bench/perl-baseline-check.pl '$(PERL_PERF_BASELINE)' '$(PERL_PERF_CURRENT)' --max-regression '$(PERL_PERF_MAX_REGRESSION)'

perl-perf-check-test:
	perl tests/perl/baseline-check.t

perl-perf-test: perl-build perl-perf-check-test
	timeout 300s perl bench/perl-baseline.pl '$(abspath $(BUILD))/perl/perl-5.42.2/perl' '$(abspath $(STOCK_PERL))' >'$(PERL_PERF_CURRENT).tmp'
	mv -- '$(PERL_PERF_CURRENT).tmp' '$(PERL_PERF_CURRENT)'
	$(MAKE) perl-perf-check

perl-mojo-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -MMojolicious -e 'die "Install the tested Mojolicious 9.37 from examples/mojo/cpanfile\n" unless $$Mojolicious::VERSION eq "9.37"'
	timeout 90s perl tests/perl/mojo-cli.t '$(abspath $(BUILD))/perl/perl-5.42.2/perl'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -Iexamples/mojo/lib tests/perl/mojo-jobs.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -Iexamples/mojo/lib tests/perl/mojo.t
	timeout 120s perl tests/perl/mojo-live.t '$(abspath $(BUILD))/perl/perl-5.42.2/perl'
	timeout 120s perl tests/perl/mojo-live.t '$(abspath $(BUILD))/perl/perl-5.42.2/perl' 1000 4

perl-mojo-example: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib examples/mojo/dashboard.pl

perl-mojo-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	@for suite in local elements publication mojo-jobs mojo; do \
		PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/mojo-'$$suite'-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -Iexamples/mojo/lib tests/perl/$$suite.t || exit $$?; \
	done

perl-source:
	bash perl/source.sh '$(BUILD)' '$(PERL_TARBALL)'

perl-fetch:
	bash perl/source.sh '$(BUILD)' --fetch

perl-build: perl-source $(BUILD)/libwump.a
	bash perl/build.sh '$(BUILD)'

perl-source-test:
	bash tests/perl/source.sh

perl-test: perl-build perl-source-test
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/baseline-check.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/entry.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/ordinary.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/active.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/waitgroup.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/preempt.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/tasks.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/xs-parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/encode-parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/bytes-parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/native-integration.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/regex-parallel.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/regex.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/local.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/elements.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/pocket.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/pocket-deparse.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/separators.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/hooks.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/locks.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/shared.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/keys.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/reads.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/read-claims.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/scalar-writes.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/operands.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/stack-loads.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/lvalue-loads.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/reference-loads.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/scalar-references.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/materialization.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/iteration.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/memory.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/publication.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/hidden-roots.t
	perl tests/perl/patcher.pl '$(BUILD)/perl/perl-5.42.2'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/refcount.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/task-context.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/clone-context.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/owned.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/allocator.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/reads.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/memory.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/writes.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/operands.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/loads.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/references.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/materialization.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/core-bugs.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/entry.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

.PHONY: perl-parallel-test perl-parallel-tsan perl-parallel-memcheck perl-parallel-bench
perl-parallel-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/owned.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/xs-parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/regex-parallel.t
	perl tests/perl/mojo-bench.t '$(BUILD)/perl/perl-5.42.2/perl'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/entry.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-parallel-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-parallel-test perl-allocator-test

perl-parallel-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/owned.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-owned-memcheck.%p.log' $(BUILD)/owned
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/parallel.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-xs-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/xs-parallel.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-regex-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/regex-parallel.t
	PERL_DESTRUCT_LEVEL=2 WUMPPROCS=4 timeout 180s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-jobs-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib bench/mojo-jobs.pl 2 2 4
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/entry.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-entry-memcheck.%p.log' $(BUILD)/interpreter-entry -I$(abspath $(BUILD))/perl/perl-5.42.2/lib
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/allocator.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 180s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/parallel-allocator-memcheck.%p.log' $(BUILD)/allocator

perl-parallel-bench: perl-build
	@for slots in 1 2 4; do \
		printf 'Perl execution slots: %s\n' "$$slots"; \
		WUMPPROCS=$$slots /usr/bin/time -f 'wall=%e user=%U system=%S' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib bench/perl-parallel.pl; result=$$?; \
		if [ "$$result" -ne 0 ]; then exit "$$result"; fi; \
	done

perl-refcount-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/refcount.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-refcount-tsan: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/refcount.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)' --tsan

perl-task-context-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/task-context.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-task-context-tsan: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/task-context.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)' --tsan

.PHONY: perl-allocator-test perl-allocator-tsan
perl-allocator-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/allocator.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-allocator-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-allocator-test

.PHONY: perl-reads-test perl-reads-tsan
perl-reads-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/reads.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-reads-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-reads-test perl-allocator-test

.PHONY: perl-writes-test perl-writes-tsan
perl-writes-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/read-claims.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/scalar-writes.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/writes.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-writes-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-writes-test perl-allocator-test

.PHONY: perl-operands-test perl-operands-tsan perl-operands-memcheck
perl-operands-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/operands.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/operands.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-operands-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-operands-test perl-allocator-test

perl-operands-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/operands-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/operands.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/operands.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/opcode-operands-memcheck.%p.log' $(BUILD)/opcode-operands

.PHONY: perl-loads-test perl-loads-tsan perl-loads-memcheck
perl-loads-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/stack-loads.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/lvalue-loads.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/loads.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-loads-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-loads-test perl-allocator-test

perl-loads-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/loads-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/stack-loads.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/lvalue-loads-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/lvalue-loads.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/loads.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/opcode-loads-memcheck.%p.log' $(BUILD)/opcode-loads

.PHONY: perl-references-test perl-references-tsan perl-references-memcheck
perl-references-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/reference-loads.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/scalar-references.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/references.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-references-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-references-test perl-allocator-test

perl-references-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/references-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/reference-loads.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/scalar-references-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/scalar-references.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/references.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/opcode-references-memcheck.%p.log' $(BUILD)/opcode-references

.PHONY: perl-materialization-test perl-materialization-tsan perl-materialization-memcheck
perl-materialization-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/materialization.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/materialization.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/core-bugs.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-materialization-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-materialization-test perl-allocator-test

perl-materialization-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/materialization-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/materialization.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/materialization.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/opcode-materialization-memcheck.%p.log' $(BUILD)/opcode-materialization
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/core-bugs.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 60s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/deferred-owner-memcheck.%p.log' $(BUILD)/deferred-owner
	timeout 60s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/deferred-target-memcheck.%p.log' $(BUILD)/deferred-target

.PHONY: perl-memory-test perl-memory-tsan
perl-memory-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/memory.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-memory-tsan:
	PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' perl-memory-test perl-allocator-test

perl-asan:
	ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1 PERL_DESTRUCT_LEVEL=2 PERL_SANITIZER=address $(MAKE) BUILD='$(BUILD)/perl-asan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls' LDFLAGS='$(LDFLAGS) -fsanitize=address' perl-test

.PHONY: perl-msan
perl-msan: sanitizer-tooling-test
	MSAN_OPTIONS=halt_on_error=1:exit_code=88 PERL_DESTRUCT_LEVEL=2 PERL_SANITIZER=memory PERL_MSAN_CC='$(MSAN_CC)' CXX='$(CLANG_CXX)' $(MAKE) BUILD='$(BUILD)/perl-msan' CC='$(MSAN_CC)' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) $(MSAN_CFLAGS)' LDFLAGS='$(LDFLAGS) $(MSAN_LDFLAGS)' msan-control perl-test

.PHONY: perl-tsan perl-ubsan perl-sanitizers perl-refcount-clang
perl-tsan:
	TSAN_OPTIONS=halt_on_error=1:exitcode=66 PERL_DESTRUCT_LEVEL=2 PERL_SANITIZER=thread $(MAKE) BUILD='$(BUILD)/perl-tsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -O1 -fsanitize=thread -fno-omit-frame-pointer' LDFLAGS='$(LDFLAGS) -fsanitize=thread' tsan-control perl-test

perl-ubsan:
	UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=89 PERL_DESTRUCT_LEVEL=2 PERL_SANITIZER=undefined $(MAKE) BUILD='$(BUILD)/perl-ubsan' PERL_TARBALL='$(abspath $(PERL_TARBALL))' CFLAGS='$(CFLAGS) -fsanitize=undefined,float-divide-by-zero -fno-sanitize-recover=all' LDFLAGS='$(LDFLAGS) -fsanitize=undefined,float-divide-by-zero' ubsan-control perl-test

perl-sanitizers:
	$(MAKE) -k -j1 perl-asan perl-lsan perl-tsan perl-ubsan perl-msan

perl-refcount-clang: perl-build
	WUMP_REFCOUNT_CC='$(CLANG)' CXX='$(CLANG_CXX)' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/refcount.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'

perl-lsan: perl-asan
	$(MAKE) BUILD='$(BUILD)/perl-asan' perl-leak-test

perl-leak-test:
	ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 PERL_DESTRUCT_LEVEL=2 timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -e '0'
	@for suite in $(PERL_SUITES); do \
		printf 'LSan Perl suite: %s\n' "$$suite"; \
		ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 PERL_DESTRUCT_LEVEL=2 timeout 120s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) "tests/perl/$$suite.t"; result=$$?; \
		if [ "$$result" -ne 0 ]; then exit "$$result"; fi; \
	done

perl-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/tasks.pl

.PHONY: perl-waitgroup-example
perl-waitgroup-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/waitgroup.pl

perl-regex-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/regex.pl

perl-local-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/local.pl

perl-elements-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/elements.pl

perl-pocket-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/pocket.pl

perl-separators-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/separators.pl

perl-safety-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/safety.pl

perl-publication-example: perl-build
	timeout 30s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib examples/publication.pl

perl-memcheck: perl-source $(BUILD)/libwump.a
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/perl-valgrind/libwump.a'
	PERL_RUNTIME_BUILD='$(BUILD)/perl-valgrind' bash perl/build.sh '$(BUILD)'
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/entry-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/entry.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/waitgroup-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/waitgroup.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/preempt-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/preempt.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/tasks.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/regex-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/regex.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/local-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/local.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/elements-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/elements.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/pocket-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/pocket.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/pocket-deparse-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/pocket-deparse.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/separators-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/separators.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/hooks-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/hooks.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/locks-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/locks.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/shared-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/shared.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/keys-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/keys.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/reads-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/reads.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/iteration-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/iteration.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/publication-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/publication.t
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/hidden-roots-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/hidden-roots.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/entry.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 60s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/entry-embed-memcheck.%p.log' $(BUILD)/interpreter-entry -I$(abspath $(BUILD))/perl/perl-5.42.2/lib
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/allocator.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/allocator-memcheck.%p.log' $(BUILD)/allocator
	timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/key-legacy-memcheck.%p.log' $(BUILD)/key-legacy
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/reads.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/readers-memcheck.%p.log' $(BUILD)/readers
	timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/read-cache-memcheck.%p.log' $(BUILD)/read-cache
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/read-claims-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/read-claims.t
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/read-claims-native-memcheck.%p.log' $(BUILD)/read-claims
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/memory-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/memory.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/memory.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/reclamation-memcheck.%p.log' $(BUILD)/reclamation
	timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/borrowed-memcheck.%p.log' $(BUILD)/borrowed
	timeout 90s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/retire-failure-memcheck.%p.log' $(BUILD)/retire-failure
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/scalar-writes-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/scalar-writes.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/writes.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/opcode-writes-memcheck.%p.log' $(BUILD)/opcode-writes
	PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/operands-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/operands.t
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/operands.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --log-file='$(BUILD)/perl/opcode-operands-memcheck.%p.log' $(BUILD)/opcode-operands

perl-upstream-test: perl-build
	$(MAKE) -C $(BUILD)/perl/perl-5.42.2 test_prep
	cd $(BUILD)/perl/perl-5.42.2/t && timeout 240s ./perl TEST -v comp/*.t re/*.t class/*.t op/anonconst.t op/const-optree.t op/args.t op/closure.t op/die.t op/eval.t op/lex.t op/local.t op/ref.t op/sort.t op/array.t op/avhv.t op/hash*.t op/each*.t op/delete.t op/localref.t op/lvref.t op/multideref.t op/push.t op/reverse.t op/splice.t op/tiearray.t op/tiehash.t op/chop.t op/readline.t op/readline_nb.t op/print.t op/sig*.t op/warn.t op/bool.t op/numconvert.t op/numify.t op/numify_chkflags.t op/svflags.t op/append.t op/concat2.t op/utf8cache.t op/utf8decode.t op/utf8magic.t op/arith2.t op/int.t op/overload_integer.t io/argv.t io/print.t io/say.t ../lib/B/Deparse.t ../lib/B/Deparse-core.t ../lib/B/Deparse-subclass.t

.PHONY: perl-upstream-full-test
perl-upstream-full-test: perl-build
	env -u PERL5LIB -u PERL5OPT -u PERL_BUILD_PACKAGING TEST_JOBS='$(PERL_FULL_TEST_JOBS)' timeout '$(PERL_FULL_TEST_TIMEOUT)s' $(MAKE) -C '$(BUILD)/perl/perl-5.42.2' test_harness_notty

.PHONY: perl-parser-test
perl-parser-test: perl-build
	perl tests/perl/parser-regeneration.pl '$(BUILD)/perl/perl-5.42.2'

.PHONY: perl-mro-upstream-test
perl-mro-upstream-test: perl-build
	$(MAKE) -C $(BUILD)/perl/perl-5.42.2 test_prep
	cd $(BUILD)/perl/perl-5.42.2/t && timeout 90s ./perl TEST -v mro/*.t op/goto.t op/goto_xs.t uni/goto.t

$(BUILD):
	mkdir -p $@

.PHONY: build-flags-force
build-flags-force:

# A reused directory must not silently retain objects from another compiler
# or an earlier sanitizer flag set. Preserve timestamps for unchanged flags.
$(BUILD)/.compile-flags: build-flags-force | $(BUILD)
	@wump_flags=$$(mktemp '$(BUILD)/.compile-flags.XXXXXX'); \
	if [ -z "$$wump_flags" ]; then exit 1; fi; \
	if ! printf '%s\n' $(call shell_quote,CC=$(CC)) $(call shell_quote,AR=$(AR)) $(call shell_quote,CPPFLAGS=$(CPPFLAGS)) $(call shell_quote,CFLAGS=$(CFLAGS)) $(call shell_quote,LDFLAGS=$(LDFLAGS)) $(call shell_quote,LDLIBS=$(LDLIBS)) >"$$wump_flags"; then rm -f -- "$$wump_flags"; exit 1; fi; \
	wump_same=1; \
	if [ -f '$@' ]; then cmp -s -- "$$wump_flags" '$@'; wump_same=$$?; fi; \
	if [ "$$wump_same" -gt 1 ]; then rm -f -- "$$wump_flags"; printf '%s\n' 'Cannot compare build configuration.' >&2; exit 1; fi; \
	if [ "$$wump_same" -eq 0 ]; then rm -f -- "$$wump_flags"; else mv -- "$$wump_flags" '$@'; fi

$(BUILD)/%.o: runtime/src/%.c runtime/src/internal.h runtime/include/wump.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

$(BUILD)/ctx_x86_64.o: runtime/src/ctx_x86_64.S | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/libwump.a: $(OBJECTS)
	$(AR) rcs $@ $^

$(BUILD)/hello: examples/hello.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/select: examples/select.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/echo: examples/echo.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/blocking: examples/blocking.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_runtime: tests/test_runtime.c tests/errno_probe.c tests/context_probe.S $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_runtime.c tests/errno_probe.c tests/context_probe.S $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_failures: tests/test_failures.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) $(addprefix -Wl$(comma)--wrap=,$(WRAPPED)) -o $@

comma := ,

$(BUILD)/test_select: tests/test_select.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_select.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_io: tests/test_io.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_io.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_syscall: tests/test_syscall.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_syscall.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_context: tests/test_context.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_syscall_failures: tests/test_syscall_failures.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_syscall_failures.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) $(addprefix -Wl$(comma)--wrap=,$(SYSCALL_WRAPPED)) -o $@

$(BUILD)/test_io_failures: tests/test_io_failures.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_io_failures.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) $(addprefix -Wl$(comma)--wrap=,$(IO_WRAPPED)) -o $@

test: $(BUILD)/test_runtime $(BUILD)/test_select $(BUILD)/test_io $(BUILD)/test_syscall $(BUILD)/test_context $(BUILD)/test_failures $(BUILD)/test_io_failures $(BUILD)/test_syscall_failures
	timeout $(TEST_TIMEOUT)s $(BUILD)/test_runtime
	timeout $(TEST_TIMEOUT)s $(BUILD)/test_select
	timeout $(TEST_TIMEOUT)s $(BUILD)/test_syscall
	timeout $(TEST_TIMEOUT)s $(BUILD)/test_context
	timeout $(TEST_LONG_TIMEOUT)s $(BUILD)/test_syscall_failures
	timeout $(TEST_TIMEOUT)s $(BUILD)/test_io
	timeout $(TEST_FAILURE_TIMEOUT)s $(BUILD)/test_failures
	timeout $(TEST_LONG_TIMEOUT)s $(BUILD)/test_io_failures

stress: $(BUILD)/test_runtime $(BUILD)/test_select $(BUILD)/test_io $(BUILD)/test_syscall
	timeout 180s $(BUILD)/test_runtime --stress
	timeout 180s $(BUILD)/test_select --stress
	timeout 180s $(BUILD)/test_syscall --stress
	timeout 180s $(BUILD)/test_io --stress

ubsan:
	UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=89 $(MAKE) $(SANITIZER_TEST_ARGS) BUILD='$(BUILD)/ubsan' CFLAGS='$(CFLAGS) -fsanitize=$(UBSAN_CHECKS) -fno-sanitize-recover=all' LDFLAGS='$(LDFLAGS) -fsanitize=$(UBSAN_CHECKS)' ubsan-control test

.PHONY: clang-ubsan gcc-ubsan cfi cfi-control ubsan-control
clang-ubsan:
	$(MAKE) CC='$(CLANG)' BUILD='$(BUILD)/clang' UBSAN_CONTROL=ubsan-clang UBSAN_CHECKS=undefined,local-bounds,float-divide-by-zero,implicit-conversion,nullability ubsan

gcc-ubsan:
	$(MAKE) CC=gcc BUILD='$(BUILD)/gcc' UBSAN_CHECKS=undefined,bounds-strict,float-divide-by-zero ubsan

cfi:
	UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=89 $(MAKE) $(SANITIZER_TEST_ARGS) BUILD='$(BUILD)/cfi' CC='$(CLANG)' AR='$(CLANG_AR)' CFLAGS='$(CFLAGS) $(CFI_CFLAGS)' LDFLAGS='$(LDFLAGS) $(CFI_LDFLAGS)' cfi-control test

$(BUILD)/ub_control: tests/ub_control.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

ubsan-control: $(BUILD)/ub_control
	bash tests/sanitizers.sh '$(BUILD)' '$(UBSAN_CONTROL)'

cfi-control: $(BUILD)/ub_control
	bash tests/sanitizers.sh '$(BUILD)' cfi

asan:
	ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1:detect_invalid_pointer_pairs=2 $(MAKE) $(SANITIZER_TEST_ARGS) BUILD='$(BUILD)/asan' CFLAGS='$(CFLAGS) -O1 -fsanitize=address,pointer-compare,pointer-subtract -fno-omit-frame-pointer -fno-optimize-sibling-calls' LDFLAGS='$(LDFLAGS) -fsanitize=address,pointer-compare,pointer-subtract' test asan-control

.PHONY: msan msan-control sanitizer-tooling-test
msan: sanitizer-tooling-test
	MSAN_OPTIONS=halt_on_error=1:exit_code=88 $(MAKE) $(SANITIZER_TEST_ARGS) BUILD='$(BUILD)/msan' CC='$(MSAN_CC)' CFLAGS='$(CFLAGS) $(MSAN_CFLAGS)' LDFLAGS='$(LDFLAGS) $(MSAN_LDFLAGS)' msan-control test

$(BUILD)/msan_control: tests/msan_control.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

msan-control: $(BUILD)/msan_control
	bash tests/sanitizers.sh '$(BUILD)' msan

sanitizer-tooling-test:
	bash tests/sanitizer-tooling.sh
	bash tests/build-flags.sh

.PHONY: sanitizers gcc-sanitizers clang-sanitizers
sanitizers:
	$(MAKE) -k -j1 gcc-sanitizers clang-sanitizers

gcc-sanitizers:
	$(MAKE) -k -j1 CC=gcc BUILD='$(BUILD)/gcc' UBSAN_CHECKS=undefined,bounds-strict,float-divide-by-zero ubsan asan lsan tsan

clang-sanitizers:
	$(MAKE) -k -j1 CC='$(CLANG)' MSAN_CC='$(CLANG)' BUILD='$(BUILD)/clang' UBSAN_CONTROL=ubsan-clang UBSAN_CHECKS=undefined,local-bounds,float-divide-by-zero,implicit-conversion,nullability ubsan asan lsan tsan msan cfi

lsan:
	ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1:detect_invalid_pointer_pairs=2 $(MAKE) $(SANITIZER_TEST_ARGS) BUILD='$(BUILD)/asan' CFLAGS='$(CFLAGS) -O1 -fsanitize=address,pointer-compare,pointer-subtract -fno-omit-frame-pointer -fno-optimize-sibling-calls' LDFLAGS='$(LDFLAGS) -fsanitize=address,pointer-compare,pointer-subtract' lsan-control test

$(BUILD)/sanitizer_control: tests/sanitizer_control.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

asan-control: $(BUILD)/sanitizer_control
	ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1:detect_invalid_pointer_pairs=2 timeout 60s $(BUILD)/sanitizer_control
	bash tests/sanitizers.sh '$(BUILD)' asan

lsan-control: $(BUILD)/sanitizer_control
	bash tests/sanitizers.sh '$(BUILD)' lsan

tsan:
	$(MAKE) $(SANITIZER_TEST_ARGS) BUILD='$(BUILD)/tsan' CFLAGS='$(CFLAGS) -fsanitize=thread' LDFLAGS='$(LDFLAGS) -fsanitize=thread' test tsan-control

.PHONY: valgrind-tools memcheck-tools helgrind drd massif callgrind cachegrind dhat bbv lackey
valgrind-tools memcheck-tools helgrind drd massif callgrind cachegrind dhat bbv lackey:
	$(MAKE) BUILD='$(BUILD)/valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' '$(BUILD)/valgrind/bench'
	bash tests/valgrind-tools.sh '$(abspath $(BUILD))/valgrind' '$(patsubst valgrind-tools,all,$(patsubst memcheck-tools,memcheck,$@))' '$(VALGRIND_ITERATIONS)' '$(VALGRIND_SLOTS)'

.PHONY: valgrind perl-valgrind perl-valgrind-run perl-valgrind-tools perl-mojo-valgrind
valgrind:
	$(MAKE) -k -j1 memcheck perl-valgrind perl-mojo-valgrind valgrind-tools perl-valgrind-tools

perl-valgrind-tools:
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' PERL_TARBALL='$(abspath $(PERL_TARBALL))' perl-build
	bash tests/valgrind-tools.sh '$(abspath $(BUILD))/perl-valgrind' all '$(VALGRIND_ITERATIONS)' '$(VALGRIND_SLOTS)' '$(abspath $(BUILD))/perl-valgrind/perl/perl-5.42.2/perl' '-I$(abspath $(BUILD))/perl-valgrind/perl/perl-5.42.2/lib' -Iperl/lib bench/mojo-jobs.pl 2 2 4

perl-mojo-valgrind:
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' PERL_TARBALL='$(abspath $(PERL_TARBALL))' perl-mojo-memcheck

perl-valgrind:
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' PERL_TARBALL='$(abspath $(PERL_TARBALL))' perl-test
	$(MAKE) BUILD='$(BUILD)/perl-valgrind' perl-valgrind-run

perl-valgrind-run:
	@for suite in $(PERL_SUITES); do \
		printf 'Memcheck Perl suite: %s\n' "$$suite"; \
		PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --trace-children=yes --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --track-origins=yes --log-file='$(BUILD)/perl/'"$$suite"'-full-memcheck.%p.log' $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) "tests/perl/$$suite.t"; result=$$?; \
		if [ "$$result" -ne 0 ]; then exit "$$result"; fi; \
	done
	@for fixture in refcount-c refcount-c++ task-context clone-context allocator key-legacy key-legacy-cpp readers read-cache read-cache-cpp borrowed borrowed-cpp reclamation retire-failure read-claims owned opcode-writes opcode-writes-cpp opcode-operands opcode-operands-cpp opcode-loads opcode-loads-cpp opcode-references opcode-references-cpp opcode-materialization opcode-materialization-cpp deferred-owner deferred-target; do \
		printf 'Memcheck native fixture: %s\n' "$$fixture"; \
		PERL_DESTRUCT_LEVEL=2 timeout 300s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --track-origins=yes --log-file='$(BUILD)/perl/'"$$fixture"'-native-full-memcheck.%p.log' '$(BUILD)/'"$$fixture"; result=$$?; \
		if [ "$$result" -ne 0 ]; then exit "$$result"; fi; \
	done
	PERL_DESTRUCT_LEVEL=2 timeout 120s valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect --track-origins=yes --log-file='$(BUILD)/perl/entry-embed-full-memcheck.%p.log' $(BUILD)/interpreter-entry -I$(abspath $(BUILD))/perl/perl-5.42.2/lib

memcheck:
	$(MAKE) BUILD='$(BUILD)/valgrind' CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' $(addprefix $(BUILD)/valgrind/test_,runtime select io syscall context syscall_failures failures io_failures)
	@for suite in runtime select syscall context syscall_failures io failures io_failures; do \
		printf 'Memcheck runtime suite: %s\n' "$$suite"; \
		timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --track-origins=yes --log-file='$(BUILD)/valgrind/'"$$suite"'.%p.log' '$(BUILD)/valgrind/test_'"$$suite"; result=$$?; \
		if [ "$$result" -ne 0 ]; then exit "$$result"; fi; \
	done

$(BUILD)/tsan_race: tests/tsan_race.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) -o $@

tsan-control: $(BUILD)/tsan_race
	@TSAN_OPTIONS=halt_on_error=1:exitcode=66 timeout 30s $(BUILD)/tsan_race > $(BUILD)/race.log 2>&1; result=$$?; \
	if [ "$$result" -eq 66 ] && grep -q 'ThreadSanitizer: data race' $(BUILD)/race.log; then \
		printf '%s\n' 'ok - TSan detects the deliberate user-data race'; \
	else cat $(BUILD)/race.log; printf '%s\n' 'FAIL: expected a TSan data-race report'; exit 1; fi

$(BUILD)/bench: bench/runtime.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

bench: $(BUILD)/bench
	timeout 180s $(BUILD)/bench $(ITERATIONS) 1
	timeout 180s $(BUILD)/bench $(ITERATIONS) 4

$(BUILD)/go-bench: bench/runtime.go | $(BUILD)
	GOTOOLCHAIN=local GOPROXY=off GOTELEMETRY=off GOCACHE=$(abspath $(BUILD)/go-cache) go build -o $@ $<

bench-compare: bench $(BUILD)/go-bench
	timeout 180s $(BUILD)/go-bench $(ITERATIONS) 1
	timeout 180s $(BUILD)/go-bench $(ITERATIONS) 4

clean:
	rm -rf $(BUILD)

$(BUILD)/test_runtime $(BUILD)/test_select $(BUILD)/test_io $(BUILD)/test_syscall: tests/test_budget.h
$(OBJECTS) $(addprefix $(BUILD)/,$(RUNTIME_PROGRAMS)): $(BUILD)/.compile-flags

-include $(OBJECTS:.o=.d)
