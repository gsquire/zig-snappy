test: snappy.zig
	zig test snappy.zig

bin: main.zig snappy.zig
	zig build-exe --release-fast main.zig

.PHONY: clean
clean:
	\rm -rf zig-cache/ main main.o
