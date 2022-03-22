const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Vector = meta.Vector;

//const block_size = config.lsm_table_block_size;
//const BlockPtr = *align(config.sector_size) [block_size]u8;
//const BlockPtrConst = *align(config.sector_size) const [block_size]u8;

pub const Layout = struct {
    ways: u64 = 16,
    tag_bits: u64 = 8,
    clock_bits: u64 = 2,
    cache_line_size: u64 = 64,
};

pub fn SetAssociativeCache(
    comptime Key: type,
    comptime Value: type,
    comptime key_from_value: fn (Value) callconv(.Inline) Key,
    comptime hash: fn (Key) callconv(.Inline) u64,
    comptime equal: fn (Key, Key) callconv(.Inline) bool,
    comptime layout: Layout,
) type {
    assert(math.isPowerOfTwo(@sizeOf(Key)));
    assert(math.isPowerOfTwo(@sizeOf(Value)));

    switch (layout.ways) {
        // An 8-way set-associative cache has the clock hand as a u3, which would introduce padding.
        2, 4, 16 => {},
        else => @compileError("ways must be 2, 4 or 16 for optimal CLOCK hand size."),
    }
    switch (layout.tag_bits) {
        8, 16 => {},
        else => @compileError("tag_bits must be 8 or 16."),
    }
    switch (layout.clock_bits) {
        1, 2, 4 => {},
        else => @compileError("clock_bits must be 1, 2 or 4."),
    }

    assert(math.isPowerOfTwo(layout.ways));
    assert(math.isPowerOfTwo(layout.tag_bits));
    assert(math.isPowerOfTwo(layout.clock_bits));
    assert(math.isPowerOfTwo(layout.cache_line_size));

    assert(@sizeOf(Key) <= @sizeOf(Value));
    assert(@sizeOf(Key) < layout.cache_line_size);
    assert(layout.cache_line_size % @sizeOf(Key) == 0);

    if (layout.cache_line_size > @sizeOf(Value)) {
        assert(layout.cache_line_size % @sizeOf(Value) == 0);
    } else {
        assert(@sizeOf(Value) % layout.cache_line_size == 0);
    }

    const clock_hand_bits = math.log2_int(u64, layout.ways);
    assert(math.isPowerOfTwo(clock_hand_bits));
    assert((1 << clock_hand_bits) == layout.ways);

    const tags_per_line = @divExact(layout.cache_line_size * 8, layout.ways * layout.tag_bits);
    assert(tags_per_line > 0);

    const clocks_per_line = @divExact(layout.cache_line_size * 8, layout.ways * layout.clock_bits);
    assert(clocks_per_line > 0);

    const clock_hands_per_line = @divExact(layout.cache_line_size * 8, clock_hand_bits);
    assert(clock_hands_per_line > 0);

    const Tag = meta.Int(.unsigned, layout.tag_bits);
    const Count = meta.Int(.unsigned, layout.clock_bits);
    const Clock = meta.Int(.unsigned, clock_hand_bits);

    const Counts = PackedUnsignedIntegerArray(Count);
    const Clocks = PackedUnsignedIntegerArray(Clock);

    return struct {
        const Self = @This();

        sets: u64,
        tags: []Tag,
        values: []Value,
        counts: []u64,
        clocks: []u64,

        pub fn init(allocator: mem.Allocator, value_count_max: u64) !Self {
            assert(math.isPowerOfTwo(value_count_max));
            assert(value_count_max > 0);
            assert(value_count_max >= layout.ways);
            assert(value_count_max % layout.ways == 0);

            const sets = @divExact(value_count_max, layout.ways);
            assert(math.isPowerOfTwo(sets));

            const value_size_max = value_count_max * @sizeOf(Value);
            assert(value_size_max >= layout.cache_line_size);
            assert(value_size_max % layout.cache_line_size == 0);

            const counts_size = @divExact(value_count_max * layout.clock_bits, 8);
            assert(counts_size >= layout.cache_line_size);
            assert(counts_size % layout.cache_line_size == 0);

            const clocks_size = @divExact(sets * clock_hand_bits, 8);
            assert(clocks_size >= layout.cache_line_size);
            assert(clocks_size % layout.cache_line_size == 0);

            const tags = try allocator.alloc(Tag, value_count_max);
            errdefer allocator.free(tags);

            const values = try allocator.alloc(Value, value_count_max);
            errdefer allocator.free(values);

            const counts = try allocator.alloc(u64, @divExact(counts_size, @sizeOf(u64)));
            errdefer allocator.free(counts);

            const clocks = try allocator.alloc(u64, @divExact(counts_size, @sizeOf(u64)));
            errdefer allocator.free(clocks);

            _ = Clocks;
            _ = Counts;

            var self = Self{
                .sets = sets,
                .tags = tags,
                .values = values,
                .counts = counts,
                .clocks = clocks,
            };

            self.reset();

            return self;
        }

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            assert(self.sets > 0);
            self.sets = 0;

            allocator.free(self.tags);
            allocator.free(self.values);
            allocator.free(self.counts);
            allocator.free(self.clocks);
        }

        pub fn reset(self: *Self) void {
            mem.set(Tag, self.tags, 0);
            mem.set(u64, self.counts, 0);
            mem.set(u64, self.clocks, 0);
        }

        pub fn get(self: *Self, key: Key) ?*Value {
            const set = self.associate(key);
            return self.search(set, key);
        }

        pub fn put(self: *Self, value: Value) void {
            const key = key_from_value(value);
            const set = self.associate(key);

            if (self.search(set, key)) |exists| {
                exists.* = value;
                return;
            }

            // TODO Find free way.
            // TODO Evict if necessary.
            const way = 0;

            set.tags[way] = set.tag;
            set.values[way] = value;

            Counts.set(self.counts, set.offset + way, 1);
        }

        fn search(self: *Self, set: Set, key: Key) ?*Value {
            for (set.tags) |tag, way| {
                // TODO self.counts.get()
                if (tag == set.tag and Counts.get(self.counts, set.offset + way) > 0) {
                    var value_ptr = &set.values[way];
                    if (equal(key_from_value(value_ptr.*), key)) return value_ptr;
                }
            }
            return null;
        }

        const Set = struct {
            tag: Tag,
            offset: u64,
            tags: *[layout.ways]Tag,
            values: *[layout.ways]Value,
        };

        inline fn associate(self: *Self, key: Key) Set {
            const entropy = hash(key);
            
            const tag = @truncate(Tag, entropy >> math.log2_int(u64, self.sets));
            const index = entropy % self.sets;
            const offset = index * layout.ways;

            return .{
                .tag = tag,
                .offset = offset,
                .tags = self.tags[offset..][0..layout.ways],
                .values = self.values[offset..][0..layout.ways],
            };
        }

        pub fn inspect() void {
            std.debug.print("Key={} Value={} ways={} tag_bits={} clock_bits={} clock_hand_bits={} tags_per_line={} clocks_per_line={} clock_hands_per_line={}\n", .{
                @bitSizeOf(Key),
                @sizeOf(Value),
                layout.ways,
                layout.tag_bits,
                layout.clock_bits,
                clock_hand_bits,
                tags_per_line,
                clocks_per_line,
                clock_hands_per_line,
            });
        }
    };
}

/// A little simpler than PackedIntArray in the std lib, restricted to little endian 64-bit words,
/// and using words exactly without padding.
fn PackedUnsignedIntegerArray(comptime UInt: type) type {
    const Word = u64;

    assert(builtin.target.cpu.arch.endian() == .Little);
    assert(@typeInfo(UInt).Int.signedness == .unsigned);
    assert(@typeInfo(UInt).Int.bits < meta.bitCount(u8));
    assert(math.isPowerOfTwo(@typeInfo(UInt).Int.bits));

    const word_bits = meta.bitCount(Word);
    const uint_bits = meta.bitCount(UInt);
    const uints_per_word = @divExact(word_bits, uint_bits);

    // An index bounded by the number of unsigned integers that fit exactly into a word.
    const WordIndex = meta.Int(.unsigned, math.log2_int(u64, uints_per_word));
    assert(math.maxInt(WordIndex) == uints_per_word - 1);

    // An index bounded by the number of bits (not unsigned integers) that fit exactly into a word.
    const BitsIndex = math.Log2Int(Word);
    assert(math.maxInt(BitsIndex) == meta.bitCount(Word) - 1);
    assert(math.maxInt(BitsIndex) == word_bits - 1);
    assert(math.maxInt(BitsIndex) == uint_bits * (math.maxInt(WordIndex) + 1) - 1);

    return struct {
        /// Returns the unsigned integer at `index`.
        pub inline fn get(words: []Word, index: u64) UInt {
            // This truncate is safe since we want to mask the right-shifted word by exactly a UInt:
            return @truncate(UInt, word(words, index).* >> bits_index(index));
        }

        /// Sets the unsigned integer at `index` to `value`.
        pub inline fn set(words: []Word, index: u64, value: UInt) void {
            const w = word(words, index);
            w.* &= ~mask(index);
            w.* |= @as(Word, value) << bits_index(index);
        }

        inline fn mask(index: u64) Word {
            return @as(Word, math.maxInt(Word)) << bits_index(index);
        }

        inline fn word(words: []Word, index: u64) *Word {
            return &words[@divFloor(index, uints_per_word)];
        }

        inline fn bits_index(index: u64) BitsIndex {
            // If uint_bits=2, then it's normal for the maximum return value value to be 62, even
            // where BitsIndex allows up to 63 (inclusive) for a 64-bit word. This is because 62 is
            // the bit index of the highest 2-bit UInt (e.g. bit index + bit length == 64).
            comptime assert(uint_bits * (math.maxInt(WordIndex) + 1) == math.maxInt(BitsIndex) + 1);

            return @as(BitsIndex, uint_bits) * @truncate(WordIndex, index);
        }
    };
}

test "PackedUnsignedIntegerArray" {
    const testing = std.testing;

    const Key = u64;
    const Value = u64;

    const context = struct {
        inline fn key_from_value(value: Value) Key {
            return value;
        }
        inline fn hash(key: Key) u64 {
            return key;
        }
        inline fn equal(a: Key, b: Key) bool {
            return a == b;
        }
    };

    const SAC = SetAssociativeCache(
        Key,
        Value,
        context.key_from_value,
        context.hash,
        context.equal,
        .{ .ways = 16 },
    );
    SAC.inspect();

    // TODO Add a nice calculator method to help solve the minimum value_count_max required:
    var sac = try SAC.init(std.testing.allocator, 16 * 16 * 8);
    defer sac.deinit(std.testing.allocator);

    std.debug.print("get() = {}\n", .{sac.get(123)});
    sac.put(123);
    std.debug.print("get() = {}\n", .{sac.get(123).?.*});

    var words = [8]u64{ 0, 0b10110010, 0, 0, 0, 0, 0, 0 };

    const p = PackedUnsignedIntegerArray(u2);

    try testing.expectEqual(@as(u2, 0b10), p.get(&words, 32 + 0));
    try testing.expectEqual(@as(u2, 0b00), p.get(&words, 32 + 1));
    try testing.expectEqual(@as(u2, 0b11), p.get(&words, 32 + 2));
    try testing.expectEqual(@as(u2, 0b10), p.get(&words, 32 + 3));

    p.set(&words, 0, 0b01);
    try testing.expectEqual(@as(u64, 0b00000001), words[0]);
    p.set(&words, 1, 0b10);
    try testing.expectEqual(@as(u64, 0b00001001), words[0]);
    p.set(&words, 2, 0b11);
    try testing.expectEqual(@as(u64, 0b00111001), words[0]);
    p.set(&words, 3, 0b11);
    try testing.expectEqual(@as(u64, 0b11111001), words[0]);
    p.set(&words, 3, 0b01);
    try testing.expectEqual(@as(u64, 0b01111001), words[0]);
    p.set(&words, 3, 0b00);
    try testing.expectEqual(@as(u64, 0b00111001), words[0]);

    p.set(&words, 4, 0b11);
    try testing.expectEqual(@as(u64, 0b0000000000000000000000000000000000000000000000000000001100111001), words[0]);
    p.set(&words, 31, 0b11);
    try testing.expectEqual(@as(u64, 0b1100000000000000000000000000000000000000000000000000001100111001), words[0]);

    //const before = 0b10110010;
    //const result = get_bits(u2, before, 0);
    //std.debug.print("\nbefore={b}\nresult={b}\n", .{ before, result});

}
