CC = cc
AR = ar
BUILD = build
ITERATIONS = 100000
CPPFLAGS = -Iruntime/include -Iruntime/src
CFLAGS = -O2 -g -std=c11 -Wall -Wextra -Werror -pthread
LDFLAGS = -pthread
LDLIBS = -lm

RUNTIME = stack sched chan io error
OBJECTS = $(addprefix $(BUILD)/,$(addsuffix .o,$(RUNTIME))) $(BUILD)/ctx_x86_64.o
WRAPPED = pthread_mutex_init pthread_cond_init pthread_condattr_init pthread_condattr_setclock posix_memalign mmap munmap mprotect pthread_create pthread_join malloc calloc realloc
IO_WRAPPED = calloc realloc pthread_mutex_init pthread_create epoll_create1 eventfd epoll_ctl epoll_wait fcntl poll __poll_chk read __read_chk write close accept4 connect getsockopt getpeername
SYSCALL_WRAPPED = calloc pthread_cond_init pthread_cond_destroy pthread_cond_broadcast pthread_create pthread_join

.PHONY: all test stress ubsan tsan tsan-control memcheck bench bench-compare clean
all: $(BUILD)/libwump.a $(BUILD)/hello $(BUILD)/select $(BUILD)/echo $(BUILD)/blocking

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

$(BUILD)/test_syscall_failures: tests/test_syscall_failures.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_syscall_failures.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) $(addprefix -Wl$(comma)--wrap=,$(SYSCALL_WRAPPED)) -o $@

$(BUILD)/test_io_failures: tests/test_io_failures.c tests/errno_probe.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_io_failures.c tests/errno_probe.c $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) $(addprefix -Wl$(comma)--wrap=,$(IO_WRAPPED)) -o $@

test: $(BUILD)/test_runtime $(BUILD)/test_select $(BUILD)/test_io $(BUILD)/test_syscall $(BUILD)/test_failures $(BUILD)/test_io_failures $(BUILD)/test_syscall_failures
	timeout 60s $(BUILD)/test_runtime
	timeout 60s $(BUILD)/test_select
	timeout 60s $(BUILD)/test_syscall
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

tsan:
	$(MAKE) BUILD=build/tsan CFLAGS='$(CFLAGS) -fsanitize=thread' LDFLAGS='$(LDFLAGS) -fsanitize=thread' test tsan-control

memcheck:
	$(MAKE) BUILD=build/valgrind CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' build/valgrind/test_runtime build/valgrind/test_select build/valgrind/test_io build/valgrind/test_syscall build/valgrind/test_syscall_failures build/valgrind/test_failures build/valgrind/test_io_failures
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/runtime.%p.log build/valgrind/test_runtime
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/select.%p.log build/valgrind/test_select
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/syscall.%p.log build/valgrind/test_syscall
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
