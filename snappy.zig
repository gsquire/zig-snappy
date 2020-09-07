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

    for (buf) |b, i| {
        if (b < 0x80) {
            if (i > 9 or (i == 9 and b > 1)) {
                return Varint{
                    .value = 0,
                    .bytesRead = -i + 1,
                };
            }
            return Varint{
                .value = x | @as(u64, b) << s,
                .bytesRead = i + 1,
            };
        }
        x |= @as(u64, b & 0x7f) << s;
        s += 7;
    }

    return Varint{
        .value = 0,
        .bytesRead = 0,
    };
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

                mem.copy(u8, dst[d..], src[s .. s + @intCast(usize, length)]);
                const l = @intCast(usize, length);
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
                offset = @as(isize, @as(u32, src[s - 2]) & 0xe0 << 3 | @as(u32, src[s - 1]));
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
            const upper_bound = d - @intCast(usize, offset) + @intCast(usize, length);
            mem.copy(u8, dst[d .. d + @intCast(usize, length)], dst[d - @intCast(usize, offset) .. upper_bound]);
            d += @intCast(usize, length);
            continue;
        }

        var a = dst[d .. d + @intCast(usize, length)];
        var b = dst[d - @intCast(usize, offset) ..];
        var aLen = a.len;
        b = b[0..aLen];
        for (a) |_, i| {
            a[i] = b[i];
        }
        d += @intCast(usize, length);
    }

    if (d != dst.len) {
        return 1;
    }

    return 0;
}

/// Given a chosen allocator and the source input, decode it using the snappy block format. The
/// returned slice must be freed.
pub fn decode(allocator: *Allocator, src: []const u8) ![]u8 {
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

test "snappy crc" {
    testing.expect(crc("snappy") == 0x293d0c23);
}

test "decoding variable integers" {
    // Taken from the block format description.
    const case1 = uvarint(&[_]u8{0x40});
    testing.expect(case1.value == 64);
    testing.expect(case1.bytesRead == 1);

    const case2 = uvarint(&[_]u8{ 0xfe, 0xff, 0x7f });
    testing.expect(case2.value == 2097150);
    testing.expect(case2.bytesRead == 3);
}

test "simple decode" {
    // TODO: Use the testing allocator?
    const allocator = std.heap.page_allocator;

    const decoded = try decode(allocator, "\x19\x1coh snap,\x05\x06,py is cool!\x0a");
    defer allocator.free(decoded);

    testing.expectEqualSlices(u8, decoded, "oh snap, snappy is cool!\n");
}
