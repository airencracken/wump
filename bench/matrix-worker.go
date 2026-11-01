package main

import (
	"encoding/json"
	"os"
	"regexp"
	"runtime"
	"runtime/debug"
	"strconv"
	"time"
)

var pattern = regexp.MustCompile(`^([a-z]+):([0-9]+)$`)

// Keep the call benchmark a call after Go's normal optimization.
//
//go:noinline
func increment(value uint64) uint64 { return value + 1 }

func compute(op string, n, id int) []any {
	var sum uint64
	var last string
	switch op {
	case "arithmetic":
		for i := 0; i < n; i++ {
			sum += uint64((i + id) % 97)
		}
	case "calls":
		for i := 0; i < n; i++ {
			sum += increment(uint64((i + id) % 97))
		}
	case "arrays":
		var retained [32][]uint64
		for i := 0; i < n; i++ {
			x := uint64((i + id) % 97)
			value := []uint64{x, x + 1, x + 2, x + 3}
			retained[i%32] = value
			sum += value[0] + value[1] + value[2] + value[3]
		}
		runtime.KeepAlive(retained)
	case "hashes":
		values := map[string]uint64{"a": 0, "b": 0, "c": 0}
		for i := 0; i < n; i++ {
			x := uint64((i + id) % 97)
			values["a"] = x
			values["b"] = values["a"] + 1
			values["c"] = values["a"] + values["b"]
			sum += values["c"]
		}
	case "strings":
		for i := 0; i < n; i++ {
			x := uint64((i + id) % 97)
			text := "abc" + strconv.FormatUint(x, 10) + ":xyz"
			sum += uint64(len(text) + len(text[:3]))
		}
	case "regex":
		for i := 0; i < n; i++ {
			x := uint64((i + id) % 97)
			parts := pattern.FindStringSubmatch("word:" + strconv.FormatUint(x, 10))
			if len(parts) != 3 {
				panic("regex mismatch")
			}
			value, err := strconv.ParseUint(parts[2], 10, 64)
			if err != nil {
				panic(err)
			}
			sum += uint64(len(parts[1])) + value
		}
	case "utf8":
		for i := 0; i < n; i++ {
			x := uint64((i + id) % 97)
			bytes := []byte(string([]rune{0x3bb, 'A' + rune(x%26)}))
			for _, value := range bytes {
				sum += uint64(value)
			}
		}
	case "json":
		for i := 0; i < n; i++ {
			x := uint64((i + id) % 97)
			value := struct {
				N uint64 `json:"n"`
				S string `json:"s"`
			}{x, "word"}
			bytes, err := json.Marshal(value)
			if err != nil {
				panic(err)
			}
			last = string(bytes)
			sum += uint64(len(bytes))
		}
	default:
		panic("invalid common operation")
	}
	if op == "json" {
		return []any{id, sum, last}
	}
	return []any{id, sum}
}

func number(value string, maximum int) int {
	n, err := strconv.Atoi(value)
	if err != nil || n < 1 || n > maximum {
		panic("invalid matrix parameter")
	}
	return n
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--identify" {
		info, ok := debug.ReadBuildInfo()
		if !ok {
			panic("Go build identity unavailable")
		}
		if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
			"version": runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH,
			"compiler": runtime.Compiler, "settings": info.Settings,
		}); err != nil {
			panic(err)
		}
		return
	}
	if len(os.Args) != 5 {
		panic("usage: matrix-worker OPERATION ITERATIONS JOBS SLOTS")
	}
	op := os.Args[1]
	n, jobs, slots := number(os.Args[2], 2000000), number(os.Args[3], 64), number(os.Args[4], 256)
	runtime.GOMAXPROCS(slots)
	primitive := op == "yield" || op == "spawn" || op == "channel"
	results := make([][]any, 0, jobs)
	start := time.Now()
	switch op {
	case "yield":
		count := 0
		for i := 0; i < n; i++ {
			runtime.Gosched()
			count++
		}
		results = append(results, []any{1, count})
	case "spawn":
		done := make(chan int)
		seen := make([]bool, n+1)
		var sum uint64
		for base := 0; base < n; base += 1024 {
			batch := min(1024, n-base)
			for id := base + 1; id <= base+batch; id++ {
				go func(id int) { done <- id }(id)
			}
			for i := 0; i < batch; i++ {
				id := <-done
				if id < 1 || id > n || seen[id] {
					panic("duplicate or invalid spawn result")
				}
				seen[id] = true
				sum += uint64(id)
			}
		}
		results = append(results, []any{1, sum})
	case "channel":
		request, response, done := make(chan int), make(chan int), make(chan bool)
		go func() {
			for i := 0; i < n; i++ {
				response <- (<-request) + 1
			}
			done <- true
		}()
		var sum uint64
		for i := 0; i < n; i++ {
			request <- i
			reply := <-response
			if reply != i+1 {
				panic("channel reply mismatch")
			}
			sum += uint64(reply)
		}
		if !<-done {
			panic("channel worker did not complete")
		}
		results = append(results, []any{1, sum})
	default:
		out := make(chan []any, 4)
		for id := 1; id <= jobs; id++ {
			go func(id int) { out <- compute(op, n, id) }(id)
		}
		for id := 0; id < jobs; id++ {
			results = append(results, <-out)
		}
	}
	elapsed := time.Since(start).Seconds()
	units := n * jobs
	if primitive {
		units = n
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
		"operation": op, "iterations": n, "jobs": jobs, "slots": runtime.GOMAXPROCS(0),
		"status": "ok", "units": units, "wall_seconds": elapsed, "results": results,
	}); err != nil {
		panic(err)
	}
}
