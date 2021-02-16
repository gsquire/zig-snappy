# zig-snappy
[![CI](https://github.com/gsquire/zig-snappy/workflows/CI/badge.svg)](https://github.com/gsquire/zig-snappy/actions)

This is a rough translation of Go's [snappy](https://github.com/golang/snappy) library for Zig. It
only supports the block format. The streaming format may be added in the future.

### Caveat
Expect some sharp edges. This is my first time writing Zig! I would greatly appreciate any issues
or pull requests to improve the code, write tests, or just critique in general.

### Roadmap
- More robust tests
- Fuzzing

### Usage
See the [binary](main.zig) in the repository.

### License
MIT
