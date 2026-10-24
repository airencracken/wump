CC = cc
AR = ar
BUILD = build
ITERATIONS = 100000
CPPFLAGS = -Iruntime/include -Iruntime/src
CFLAGS = -O2 -g -std=c11 -Wall -Wextra -Werror -pthread
LDFLAGS = -pthread
LDLIBS = -lm

RUNTIME = stack sched chan
OBJECTS = $(addprefix $(BUILD)/,$(addsuffix .o,$(RUNTIME))) $(BUILD)/ctx_x86_64.o
WRAPPED = pthread_mutex_init pthread_cond_init posix_memalign mmap munmap mprotect pthread_create pthread_join malloc calloc

.PHONY: all test stress ubsan tsan tsan-control memcheck bench bench-compare clean
all: $(BUILD)/libwump.a $(BUILD)/hello

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

$(BUILD)/test_runtime: tests/test_runtime.c tests/errno_probe.c tests/context_probe.S $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_runtime.c tests/errno_probe.c tests/context_probe.S $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/test_failures: tests/test_failures.c $(BUILD)/libwump.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libwump.a $(LDFLAGS) $(LDLIBS) $(addprefix -Wl$(comma)--wrap=,$(WRAPPED)) -o $@

comma := ,

test: $(BUILD)/test_runtime $(BUILD)/test_failures
	timeout 60s $(BUILD)/test_runtime
	timeout 30s $(BUILD)/test_failures

stress: $(BUILD)/test_runtime
	timeout 180s $(BUILD)/test_runtime --stress

ubsan:
	$(MAKE) BUILD=build/ubsan CFLAGS='$(CFLAGS) -fsanitize=undefined -fno-sanitize-recover=all' LDFLAGS='$(LDFLAGS) -fsanitize=undefined' test

tsan:
	$(MAKE) BUILD=build/tsan CFLAGS='$(CFLAGS) -fsanitize=thread' LDFLAGS='$(LDFLAGS) -fsanitize=thread' test tsan-control

memcheck:
	$(MAKE) BUILD=build/valgrind CPPFLAGS='$(CPPFLAGS) -DWUMP_VALGRIND' build/valgrind/test_runtime build/valgrind/test_failures
	timeout 300s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/runtime.%p.log build/valgrind/test_runtime
	timeout 120s valgrind --error-exitcode=99 --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect --log-file=build/valgrind/failures.%p.log build/valgrind/test_failures

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
