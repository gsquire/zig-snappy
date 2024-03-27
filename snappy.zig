const std = @import("std");
const Allocator = std.mem.Allocator;
const crc32 = std.hash.crc;
const mem = std.mem;
const testing = std.testing;

const tagLiteral = 0x00;
const tagCopy1 = 0x01;
const tagCopy2 = 0x02;
const tagCopy4 = 0x03;

const checksumSize = 4;
const chunkHeaderSize = 4;
const magicBody = "sNaPpY";
const magicChunk = "\xff\x06\x00\x00" ++ magicBody;

const maxBlockSize = 65536;
const maxEncodedLenOfMaxBlockSize = 76490;

const inputMargin = 16 - 1;
const minNonLiteralBlockSize = 1 + 1 + inputMargin;

const obufHeaderLen = magicChunk.len + checksumSize + chunkHeaderSize;
const obufLen = obufHeaderLen + maxEncodedLenOfMaxBlockSize;

const chunkTypeCompressedData = 0x00;
const chunkTypeUncompressedData = 0x01;
const chunkTypePadding = 0xfe;
const chunkTypeStreamIdentifier = 0xff;

// Various errors that may occur while decoding.
const SnappyError = error{
    Corrupt,
    TooLarge,
    Unsupported,
};

// Perform the CRC hash per the snappy documentation. We must use wrapping addition since this is
// the default behavior in other languages.
fn crc(b: []const u8) u32 {
    const c = crc32.Crc32SmallWithPoly(.Castagnoli);
    const hash = c.hash(b);
    return @as(u32, hash >> 15 | hash << 17) +% 0xa282ead8;
}

// Represents a variable length integer that we read from a byte stream along with how many bytes
// were read to decode it.
const Varint = struct {
    value: u64,
    bytesRead: usize,
};

// https://golang.org/pkg/encoding/binary/#Uvarint
fn uvarint(buf: []const u8) Varint {
    var x: u64 = 0;
    var s: u6 = 0; // We can shift a maximum of 2^6 (64) times.

    for (buf, 0..) |b, i| {
        if (b < 0x80) {
            if (i > 9 or i == 9 and b > 1) {
                return Varint{
                    .value = 0,
                    .bytesRead = -%i + 1,
                };
            }
            return Varint{
                .value = x | (@as(u64, b) << s),
                .bytesRead = i + 1,
            };
        }
        x |= (@as(u64, b & 0x7f) << s);
        s += 7;
    }

    return Varint{
        .value = 0,
        .bytesRead = 0,
    };
}

// https://golang.org/pkg/encoding/binary/#PutUvarint
fn putUvarint(buf: []u8, x: u64) usize {
    var i: usize = 0;
    var mutX = x;

    while (mutX >= 0x80) {
        buf[i] = @as(u8, @truncate(mutX)) | 0x80;
        mutX >>= 7;
        i += 1;
    }
    buf[i] = @as(u8, @truncate(mutX));

    return i + 1;
}

// This type represents the size of the snappy block and the header length.
const SnappyBlock = struct {
    blockLen: u64,
    headerLen: usize,
};

// Return the length of the decoded block and the number of bytes that the header occupied.
fn decodedLen(src: []const u8) !SnappyBlock {
    const varint = uvarint(src);
    if (varint.bytesRead <= 0 or varint.value > 0xffffffff) {
        return SnappyError.Corrupt;
    }

    const wordSize = 32 << (-1 >> 32 & 1);
    if (wordSize == 32 and varint.value > 0x7fffffff) {
        return SnappyError.TooLarge;
    }

    return SnappyBlock{
        .blockLen = varint.value,
        .headerLen = varint.bytesRead,
    };
}

// The block format decoding implementation.
fn runDecode(dst: []u8, src: []const u8) u8 {
    var d: usize = 0;
    var s: usize = 0;
    var offset: isize = 0;
    var length: isize = 0;

    while (s < src.len) {
        switch (src[s] & 0x03) {
            tagLiteral => {
                var x = @as(u32, src[s] >> 2);
                switch (x) {
                    0...59 => s += 1,
                    60 => {
                        s += 2;
                        if (s > src.len) {
                            return 1;
                        }
                        x = @as(u32, src[s - 1]);
                    },
                    61 => {
                        s += 3;
                        if (s > src.len) {
                            return 1;
                        }
                        x = @as(u32, src[s - 2]) | @as(u32, src[s - 1]) << 8;
                    },
                    62 => {
                        s += 4;
                        if (s > src.len) {
                            return 1;
                        }
                        x = @as(u32, src[s - 3]) | @as(u32, src[s - 2]) << 8 | @as(u32, src[s - 1]) << 16;
                    },
                    63 => {
                        s += 5;
                        if (s > src.len) {
                            return 1;
                        }
                        x = @as(u32, src[s - 4]) | @as(u32, src[s - 3]) << 8 | @as(u32, src[s - 2]) << 16 | @as(u32, src[s - 1]) << 24;
                    },
                    // Should be unreachable.
                    else => {
                        return 1;
                    },
                }
                length = @as(isize, x) + 1;
                if (length <= 0) {
                    return 1;
                }

                if (length > dst.len - d or length > src.len - s) {
                    return 1;
                }

                mem.copy(u8, dst[d..], src[s .. s + @as(usize, @intCast(length))]);
                const l = @as(usize, @intCast(length));
                d += l;
                s += l;
                continue;
            },
            tagCopy1 => {
                s += 2;
                if (s > src.len) {
                    return 1;
                }

                length = 4 + (@as(isize, src[s - 2]) >> 2 & 0x7);
                offset = @as(isize, (@as(u32, src[s - 2]) & 0xe0) << 3 | @as(u32, src[s - 1]));
            },
            tagCopy2 => {
                s += 3;
                if (s > src.len) {
                    return 1;
                }

                length = 1 + (@as(isize, src[s - 3]) >> 2);
                offset = @as(isize, @as(u32, src[s - 2]) | @as(u32, src[s - 1]) << 8);
            },
            tagCopy4 => {
                s += 5;
                if (s > src.len) {
                    return 1;
                }

                length = 1 + (@as(isize, src[s - 5]) >> 2);
                offset = @as(isize, @as(u32, src[s - 4]) | @as(u32, src[s - 3]) << 8 | @as(u32, src[s - 2]) << 16 | @as(u32, src[s - 1]) << 24);
            },
            // Should be unreachable.
            else => {
                return 1;
            },
        }

        if (offset <= 0 or d < offset or length > dst.len - d) {
            return 1;
        }

        if (offset >= length) {
            const upper_bound = d - @as(usize, @intCast(offset)) + @as(usize, @intCast(length));
            mem.copy(u8, dst[d .. d + @as(usize, @intCast(length))], dst[d - @as(usize, @intCast(offset)) .. upper_bound]);
            d += @as(usize, @intCast(length));
            continue;
        }

        var a = dst[d .. d + @as(usize, @intCast(length))];
        var b = dst[d - @as(usize, @intCast(offset)) ..];
        var aLen = a.len;
        b = b[0..aLen];
        for (a, 0..) |_, i| {
            a[i] = b[i];
        }
        d += @as(usize, @intCast(length));
    }

    if (d != dst.len) {
        return 1;
    }

    return 0;
}

/// Given a chosen allocator and the source input, decode it using the snappy block format. The
/// returned slice must be freed.
pub fn decode(allocator: Allocator, src: []const u8) ![]u8 {
    const block = try decodedLen(src);

    var dst = try allocator.alloc(u8, block.blockLen);
    errdefer allocator.free(dst);

    // Skip past how many bytes we read to get the length.
    var s = src[block.headerLen..];

    if (runDecode(dst, s) != 0) {
        return SnappyError.Corrupt;
    }

    return dst;
}

// TODO: Split up encode and decode into separate files once I better understand modules.
fn emitLiteral(dst: []u8, lit: []const u8) usize {
    var i: usize = 0;
    const n = @as(usize, @intCast(lit.len - 1));
    switch (n) {
        0...59 => {
            dst[0] = @as(u8, @intCast(n)) << 2 | tagLiteral;
            i = 1;
        },
        60...255 => {
            dst[0] = 60 << 2 | tagLiteral;
            dst[1] = @as(u8, @intCast(n));
            i = 2;
        },
        else => {
            dst[0] = 61 << 2 | tagLiteral;
            dst[1] = @as(u8, @intCast(n));
            dst[2] = @as(u8, @intCast(n >> 8));
            i = 3;
        },
    }
    mem.copy(u8, dst[i..], lit);

    return i + @min(dst.len, lit.len);
}

fn load32(b: []u8, i: isize) u32 {
    const j = @as(usize, @intCast(i));
    const v = b[j .. j + 4];
    return @as(u32, @intCast(v[0])) | @as(u32, @intCast(v[1])) << 8 | @as(u32, @intCast(v[2])) << 16 | @as(u32, @intCast(v[3])) << 24;
}

fn load64(b: []u8, i: isize) u64 {
    const j = @as(usize, @intCast(i));
    const v = b[j .. j + 8];
    return @as(u64, @intCast(v[0])) | @as(u64, @intCast(v[1])) << 8 | @as(u64, @intCast(v[2])) << 16 | @as(u64, @intCast(v[3])) << 24 | @as(u64, @intCast(v[4])) << 32 | @as(u64, @intCast(v[5])) << 40 | @as(u64, @intCast(v[6])) << 48 | @as(u64, @intCast(v[7])) << 56;
}

fn snappyHash(u: u32, shift: u32) u32 {
    const s = @as(u5, @intCast(shift));
    return (u *% 0x1e35a7bd) >> s;
}

fn emitCopy(dst: []u8, offset: isize, length: isize) usize {
    var i: usize = 0;
    var l: isize = length;

    while (l >= 68) {
        dst[i + 0] = 63 << 2 | tagCopy2;
        dst[i + 1] = @as(u8, @truncate(@as(usize, @intCast(offset))));
        dst[i + 2] = @as(u8, @truncate(@as(usize, @intCast(offset >> 8))));
        i += 3;
        l -= 64;
    }

    if (l > 64) {
        dst[i + 0] = 59 << 2 | tagCopy2;
        dst[i + 1] = @as(u8, @truncate(@as(usize, @intCast(offset))));
        dst[i + 2] = @as(u8, @truncate(@as(usize, @intCast(offset >> 8))));
        //mem.copy(u8, dst, &mem.toBytes(offset));
        i += 3;
        l -= 60;
    }

    if (l >= 12 or offset >= 2048) {
        dst[i + 0] = (@as(u8, @intCast(l)) -% 1) << 2 | tagCopy2;
        dst[i + 1] = @as(u8, @truncate(@as(usize, @intCast(offset))));
        dst[i + 2] = @as(u8, @truncate(@as(usize, @intCast(offset >> 8))));
        return i + 3;
    }

    dst[i + 0] = @as(u8, @truncate(@as(usize, @intCast(offset >> 8)))) << 5 | (@as(u8, @intCast(l)) -% 4) << 2 | tagCopy1;
    dst[i + 1] = @as(u8, @truncate(@as(usize, @intCast(offset))));
    return i + 2;
}

fn encodeBlock(dst: []u8, src: []u8) usize {
    const maxTableSize = 1 << 14;
    const tableMask = maxTableSize - 1;

    var d: usize = 0;
    var shift: u32 = 24;
    var tableSize: isize = 1 << 8;
    while (tableSize < maxTableSize and tableSize < src.len) {
        tableSize *= 2;
        shift -= 1;
    }

    var table = mem.zeroes([maxTableSize]u16);
    var sLimit = src.len - inputMargin;
    var nextEmit: usize = 0;
    var s: usize = 1;
    var nextHash = snappyHash(load32(src, @as(isize, @intCast(s))), shift);

    outer: while (true) {
        var skip: isize = 32;
        var nextS = s;
        var candidate: isize = 0;

        inner: while (true) {
            s = nextS;
            var bytesBetweenHashLookups = skip >> 5;
            nextS = s + @as(usize, @intCast(bytesBetweenHashLookups));
            skip += bytesBetweenHashLookups;
            if (nextS > sLimit) {
                break :outer;
            }
            candidate = @as(isize, @intCast(table[nextHash & tableMask]));
            table[nextHash & tableMask] = @as(u16, @intCast(s));
            nextHash = snappyHash(load32(src, @as(isize, @intCast(nextS))), shift);
            if (load32(src, @as(isize, @intCast(s))) == load32(src, candidate)) {
                break :inner;
            }
        }

        d += emitLiteral(dst[d..], src[nextEmit..s]);

        while (true) {
            var base = s;
            s += 4;
            var i = @as(usize, @intCast(candidate + 4));
            while (s < src.len and src[i] == src[s]) {
                i += 1;
                s += 1;
            }

            d += emitCopy(dst[d..], @as(isize, @intCast(base - @as(usize, @intCast(candidate)))), @as(isize, @intCast(s - base)));
            nextEmit = s;
            if (s >= sLimit) {
                break :outer;
            }

            var x = load64(src, @as(isize, @intCast(s - 1)));
            var prevHash = snappyHash(@as(u32, @truncate(x >> 0)), shift);
            table[prevHash & tableMask] = @as(u16, @intCast(s - 1));
            var currHash = snappyHash(@as(u32, @truncate(x >> 8)), shift);
            candidate = @as(isize, @intCast(table[currHash & tableMask]));
            table[currHash & tableMask] = @as(u16, @intCast(s));
            if (@as(u32, @truncate(x >> 8)) != load32(src, candidate)) {
                nextHash = snappyHash(@as(u32, @truncate(x >> 16)), shift);
                s += 1;
                break;
            }
        }
    }

    if (nextEmit < src.len) {
        d += emitLiteral(dst[d..], src[nextEmit..]);
    }

    return d;
}

/// Encode returns the encoded form of the source input. The returned slice must be freed.
pub fn encode(allocator: Allocator, src: []u8) ![]u8 {
    var mutSrc = src;
    const encodedLen = maxEncodedLen(mutSrc.len);
    if (encodedLen < 0) {
        return SnappyError.TooLarge;
    }

    var dst = try allocator.alloc(u8, @as(usize, @intCast(encodedLen)));
    errdefer allocator.free(dst);

    var d = putUvarint(dst, @as(u64, @intCast(mutSrc.len)));

    while (mutSrc.len > 0) {
        var p = try allocator.alloc(u8, mutSrc.len);
        mem.copy(u8, p, mutSrc);
        var empty = [_]u8{};
        mutSrc = empty[0..];
        if (p.len > maxBlockSize) {
            mutSrc = p[maxBlockSize..];
            p = p[0..maxBlockSize];
        }
        if (p.len < minNonLiteralBlockSize) {
            d += emitLiteral(dst[d..], p);
        } else {
            d += encodeBlock(dst[d..], p);
        }
        allocator.free(p);
    }

    return dst[0..d];
}

/// Return the maximum length of a snappy block, given the uncompressed length.
pub fn maxEncodedLen(srcLen: usize) isize {
    var n = @as(u64, @intCast(srcLen));
    if (n > 0xffffffff) {
        return -1;
    }

    n = 32 + n + n / 6;
    if (n > 0xffffffff) {
        return -1;
    }

    return @as(isize, @intCast(n));
}

test "snappy crc" {
    try testing.expect(crc("snappy") == 0x293d0c23);
}

test "decoding variable integers" {
    // Taken from the block format description.
    const case1 = uvarint(&[_]u8{0x40});
    try testing.expect(case1.value == 64);
    try testing.expect(case1.bytesRead == 1);

    const case2 = uvarint(&[_]u8{ 0xfe, 0xff, 0x7f });
    try testing.expect(case2.value == 2097150);
    try testing.expect(case2.bytesRead == 3);
}

test "simple decode" {
    // TODO: Use the testing allocator?
    const allocator = std.heap.page_allocator;

    const decoded = try decode(allocator, "\x19\x1coh snap,\x05\x06,py is cool!\x0a");
    defer allocator.free(decoded);

    try testing.expectEqualSlices(u8, decoded, "oh snap, snappy is cool!\n");
}
