package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"time"
)

var count = 100000

func report(name string, operations uint64, started time.Time) {
	seconds := time.Since(started).Seconds()
	fmt.Printf("go,%s,%d,%d,%.6f,%.1f\n", name, runtime.GOMAXPROCS(0),
		operations, seconds, seconds*1e9/float64(operations))
}

func spawnBench() {
	done := make(chan struct{})
	started := time.Now()
	for base := 0; base < count; base += 1024 {
		batch := min(count-base, 1024)
		for i := 0; i < batch; i++ {
			go func() { done <- struct{}{} }()
		}
		for i := 0; i < batch; i++ {
			<-done
		}
	}
	report("spawn", uint64(count), started)
}

func yieldBench() {
	started := time.Now()
	for i := 0; i < count; i++ {
		runtime.Gosched()
	}
	report("yield", uint64(count), started)
}

func pingBench() {
	request, response := make(chan int32), make(chan int32)
	done := make(chan struct{})
	started := time.Now()
	go func() {
		for i := 0; i < count; i++ {
			response <- <-request + 1
		}
		done <- struct{}{}
	}()
	for i := 0; i < count; i++ {
		request <- int32(i)
		if <-response != int32(i+1) {
			panic("pingpong value mismatch")
		}
	}
	<-done
	report("pingpong", uint64(count), started)
}

type summary struct{ count, sum uint64 }

func mpmcBench() {
	data := make(chan uint64, 64)
	produced := make(chan struct{})
	consumed := make(chan summary)
	started := time.Now()
	for i := 0; i < 4; i++ {
		go func(index int) {
			for j := count * index / 4; j < count*(index+1)/4; j++ {
				data <- uint64(j)
			}
			produced <- struct{}{}
		}(i)
		go func() {
			var result summary
			for value := range data {
				result.count++
				result.sum += value
			}
			consumed <- result
		}()
	}
	for i := 0; i < 4; i++ {
		<-produced
	}
	close(data)
	var total summary
	for i := 0; i < 4; i++ {
		result := <-consumed
		total.count += result.count
		total.sum += result.sum
	}
	if total.count != uint64(count) || total.sum != uint64(count)*uint64(count-1)/2 {
		panic("mpmc count or checksum mismatch")
	}
	report("mpmc", uint64(count), started)
}

func compute(x uint64) uint64 {
	for i := uint64(0); i < uint64(count)*64; i++ {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
	}
	return x
}

func cpuBench() {
	done := make(chan uint64)
	started := time.Now()
	for i := 1; i <= 4; i++ {
		go func(seed uint64) { done <- compute(seed) }(uint64(i))
	}
	var checksum uint64
	for i := 0; i < 4; i++ {
		checksum ^= <-done
	}
	report("cpu", uint64(count)*64*4, started)
	if checksum != compute(4) {
		panic("cpu checksum mismatch")
	}
}

func number(value string) int {
	n, err := strconv.Atoi(value)
	if err != nil || n <= 0 || n > 1073741823 {
		panic("invalid positive integer: " + value)
	}
	return n
}

func main() {
	if len(os.Args) > 3 {
		panic("usage: runtime [iterations [workers]]")
	}
	if len(os.Args) > 1 {
		count = number(os.Args[1])
	}
	workers := 1
	if len(os.Args) > 2 {
		workers = number(os.Args[2])
	}
	runtime.GOMAXPROCS(workers)
	fmt.Println("implementation,workload,workers,operations,seconds,ns_per_op")
	for _, benchmark := range []func(){spawnBench, yieldBench, pingBench, mpmcBench, cpuBench} {
		benchmark()
	}
}
