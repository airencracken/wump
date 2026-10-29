CC = cc
AR = ar
BUILD = build
ITERATIONS = 100000
PERL_TARBALL = $(BUILD)/perl/perl-5.42.2.tar.xz
CPPFLAGS = -Iruntime/include -Iruntime/src
CFLAGS = -O2 -g -std=c11 -Wall -Wextra -Werror -pthread
LDFLAGS = -pthread
LDLIBS = -lm
PERL_SUITES = entry waitgroup preempt tasks parallel xs-parallel regex-parallel regex local elements pocket pocket-deparse separators hooks locks shared keys reads read-claims scalar-writes operands stack-loads lvalue-loads reference-loads scalar-references materialization iteration memory publication hidden-roots

RUNTIME = stack sched chan io error
OBJECTS = $(addprefix $(BUILD)/,$(addsuffix .o,$(RUNTIME))) $(BUILD)/ctx_x86_64.o
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

perl-mojo-test: perl-build
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -MMojolicious -e 'die "Install the tested Mojolicious 9.37 from examples/mojo/cpanfile\n" unless $$Mojolicious::VERSION eq "9.37"'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -Iexamples/mojo/lib tests/perl/mojo-jobs.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -Iexamples/mojo/lib tests/perl/mojo.t
	timeout 120s perl tests/perl/mojo-live.t '$(abspath $(BUILD))/perl/perl-5.42.2/perl'

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
	$(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib tests/perl/root-fixture.pl '$(BUILD)/perl/perl-5.42.2' '$(BUILD)'
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/entry.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/waitgroup.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/preempt.t
	timeout 90s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib tests/perl/tasks.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/parallel.t
	timeout 180s $(BUILD)/perl/perl-5.42.2/perl -I$(BUILD)/perl/perl-5.42.2/lib -Iperl/lib -I$(BUILD) tests/perl/xs-parallel.t
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

$(BUILD):
	mkdir -p $@

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
	timeout 60s $(BUILD)/test_runtime
	timeout 60s $(BUILD)/test_select
	timeout 60s $(BUILD)/test_syscall
	timeout 60s $(BUILD)/test_context
	timeout 90s $(BUILD)/test_syscall_failures
	timeout 60s $(BUILD)/test_io
	timeout 30s $(BUILD)/test_failures
	timeout 90s $(BUILD)/test_io_failures

stress: $(BUILD)/test_runtime $(BUILD)/test_select $(BUILD)/test_io $(BUILD)/test_syscall
	timeout 180s $(BUILD)/test_runtime --stress
	timeout 180s $(BUILD)/test_select --stress
	timeout 180s $(BUILD)/test_syscall --stress
	timeout 180s $(BUILD)/test_io --stress

ubsan:
	$(MAKE) BUILD=build/ubsan CFLAGS='$(CFLAGS) -fsanitize=undefined -fno-sanitize-recover=all' LDFLAGS='$(LDFLAGS) -fsanitize=undefined' test

asan:
	ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1 $(MAKE) BUILD='$(BUILD)/asan' CFLAGS='$(CFLAGS) -O1 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls' LDFLAGS='$(LDFLAGS) -fsanitize=address' test asan-control

lsan:
	ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 $(MAKE) BUILD='$(BUILD)/asan' CFLAGS='$(CFLAGS) -O1 -fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls' LDFLAGS='$(LDFLAGS) -fsanitize=address' lsan-control test

$(BUILD)/sanitizer_control: tests/sanitizer_control.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

asan-control: $(BUILD)/sanitizer_control
	ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=1 timeout 60s $(BUILD)/sanitizer_control
	bash tests/sanitizers.sh '$(BUILD)' asan

lsan-control: $(BUILD)/sanitizer_control
	bash tests/sanitizers.sh '$(BUILD)' lsan

tsan:
	$(MAKE) BUILD=build/tsan CFLAGS='$(CFLAGS) -fsanitize=thread' LDFLAGS='$(LDFLAGS) -fsanitize=thread' test tsan-control

memcheck:
	$(MAKE) BUILD=build/valgrind CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' build/valgrind/test_runtime build/valgrind/test_select build/valgrind/test_io build/valgrind/test_syscall build/valgrind/test_context build/valgrind/test_syscall_failures build/valgrind/test_failures build/valgrind/test_io_failures
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/runtime.%p.log build/valgrind/test_runtime
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/select.%p.log build/valgrind/test_select
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/syscall.%p.log build/valgrind/test_syscall
	timeout 180s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/context.%p.log build/valgrind/test_context
	timeout 180s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/syscall-failures.%p.log build/valgrind/test_syscall_failures
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/io.%p.log build/valgrind/test_io
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/failures.%p.log build/valgrind/test_failures
	timeout 180s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/io-failures.%p.log build/valgrind/test_io_failures

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

-include $(OBJECTS:.o=.d)
