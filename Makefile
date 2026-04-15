.PHONY: build test run check clean fmt run-metrics sanitize

build:
	zig build

test:
	zig build test

run:
	zig build run

fmt:
	zig fmt src/ build.zig

check:
	zig fmt --check src/ build.zig
	zig build test

run-metrics:
	zig build -Dmetrics=true run

sanitize:
	zig build -Doptimize=ReleaseSafe test

clean:
	rm -rf zig-out .zig-cache zag-trace.json
