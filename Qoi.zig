const std = @import("std");

const OP_RGB = 0b1111_1110;
const OP_RGBA = 0b1111_1111;

const OP_INDEX = 0b0000_0000;
const OP_DIFF = 0b0100_0000;
const OP_LUMA = 0b1000_0000;
const OP_RUN = 0b1100_0000;

const magic_start = "qoif";
const magic_end = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

const Self = @This();

width: u32,
height: u32,
pixels: []u8,
allocator: std.mem.Allocator,

fn smb(chunk: u8, shift: u3, bias: u8) u8 {
    const mask = (bias * 2) - 1;
    return ((chunk >> shift) & mask) -% bias;
}

pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) !Self {
    const start = try reader.readBytesNoEof(4);
    if (!std.mem.eql(u8, &start, magic_start)) {
        return error.QoiCorrupt;
    }

    const w = try reader.readInt(u32, .big);
    const h = try reader.readInt(u32, .big);

    _ = try reader.readBytesNoEof(2);

    var pixels = try allocator.alloc([4]u8, w * h);
    errdefer allocator.free(pixels);

    var pixel = [4]u8{ 0, 0, 0, 255 };
    var array = std.mem.zeroes([64][4]u8);

    var i: u32 = 0;
    while (i < w * h) {
        const chunk = try reader.readByte();

        switch (chunk) {
            OP_RGB => pixel[0..3].* = try reader.readBytesNoEof(3),
            OP_RGBA => pixel = try reader.readBytesNoEof(4),
            else => {
                const chunk_high = chunk & 0b1100_0000;
                const chunk_low = chunk & 0b0011_1111;

                switch (chunk_high) {
                    OP_INDEX => pixel = array[chunk_low],
                    OP_DIFF => {
                        pixel[0] = smb(chunk, 4, 2);
                        pixel[1] = smb(chunk, 2, 2);
                        pixel[2] = smb(chunk, 0, 2);
                    },
                    OP_LUMA => {
                        const dg = smb(chunk, 0, 32);
                        const drb = try reader.readByte();
                        pixel[0] +%= dg +% smb(drb, 4, 8);
                        pixel[1] +%= dg;
                        pixel[2] +%= dg +% smb(drb, 0, 8);
                    },
                    OP_RUN => {
                        const end = i + chunk_low + 1;
                        if (end > w * h) return error.QoiCorrupt;
                        @memset(pixels[i..end], pixel);
                        i = end;
                        continue;
                    },
                    else => unreachable,
                }
            },
        }

        const hash = pixel[0] *% 3 +% pixel[1] *% 5 +% pixel[2] *% 7 +% pixel[3] *% 11;
        array[hash & 0x3F] = pixel;
        pixels[i] = pixel;
        i += 1;
    }

    const end = try reader.readBytesNoEof(8);
    if (!std.mem.eql(u8, &end, &magic_end)) {
        return error.QoiCorrupt;
    }

    const pixels_slice = @as([*]u8, @ptrCast(pixels))[0 .. 4 * w * h];
    return .{
        .width = w,
        .height = h,
        .pixels = pixels_slice,
        .allocator = allocator,
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.pixels);
}
