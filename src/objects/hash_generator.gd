class_name HashGenerator

static func generate_object_hash(dupe_map: Dictionary, type: String, obj_path: String) -> int:
	var t: String = "Type:" + type + "->" + obj_path
	dupe_map[t] = dupe_map.get(t, -1) + 1
	t += str(dupe_map[t])
	var ret: int = xxHash64(t.to_utf8_buffer())
	return ret

static func unsrs(n: int, shift: int) -> int:
	return ((n >> 1) & 0x7fffffffffffffff) >> (shift - 1)

static func xxHash64(buffer: PackedByteArray, seed = 0) -> int:
	# https://github.com/Jason3S/xxhash
	# MIT License
	#
	# Copyright (c) 2019 Jason Dent
	#
	# Permission is hereby granted, free of charge, to any person obtaining a copy
	# of this software and associated documentation files (the "Software"), to deal
	# in the Software without restriction, including without limitation the rights
	# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	# copies of the Software, and to permit persons to whom the Software is
	# furnished to do so, subject to the following conditions:
	#
	# The above copyright notice and this permission notice shall be included in all
	# copies or substantial portions of the Software.
	#
	# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	# SOFTWARE.
	#
	# Parts based on https://github.com/Cyan4973/xxHash
	# xxHash Library - Copyright (c) 2012-2021 Yann Collet (BSD 2-clause)

	var b: PackedByteArray = buffer.slice(0)
	var len_buffer: int = len(buffer)
	b.resize((len_buffer + 7) & (~7))
	var b32: PackedInt32Array = b.to_int32_array()
	var b64: PackedInt64Array = b.to_int64_array()

	const PRIME64_1 = -7046029288634856825
	const PRIME64_2 = -4417276706812531889
	const PRIME64_3 = 1609587929392839161
	const PRIME64_4 = -8796714831421723037
	const PRIME64_5 = 2870177450012600261
	var acc: int = seed + PRIME64_5
	var offset: int = 0

	if len_buffer >= 32:
		var accN: PackedInt64Array = (
			PackedInt64Array(
				[
					seed + PRIME64_1 + PRIME64_2,
					seed + PRIME64_2,
					seed + 0,
					seed - PRIME64_1,
				]
			)
			. duplicate()
		)
		var limit: int = len_buffer - 32
		var lane: int = 0
		offset = 0
		while (offset & 0xffffffe0) <= limit:
			accN[lane] += b64[offset / 8] * PRIME64_2
			accN[lane] = ((accN[lane] << 31) | unsrs(accN[lane], 33)) * PRIME64_1
			offset += 8
			lane = (lane + 1) & 3
		acc = (((accN[0] << 1) | unsrs(accN[0], 63)) + ((accN[1] << 7) | unsrs(accN[1], 57)) + ((accN[2] << 12) | unsrs(accN[2], 52)) + ((accN[3] << 18) | unsrs(accN[3], 46)))
		for i in range(4):
			accN[i] = accN[i] * PRIME64_2
			accN[i] = ((accN[i] << 31) | unsrs(accN[i], 33)) * PRIME64_1
			acc = acc ^ accN[i]
			acc = acc * PRIME64_1 + PRIME64_4

	acc = acc + len_buffer
	var limit = len_buffer - 8
	while offset <= limit:
		var k1: int = b64[offset / 8] * PRIME64_2
		acc ^= ((k1 << 31) | unsrs(k1, 33)) * PRIME64_1
		acc = ((acc << 27) | unsrs(acc, 37)) * PRIME64_1 + PRIME64_4
		offset += 8

	limit = len_buffer - 4
	if offset <= limit:
		acc = acc ^ (b32[offset / 4] * PRIME64_1)
		acc = ((acc << 23) | unsrs(acc, 41)) * PRIME64_2 + PRIME64_3
		offset += 4

	while offset < len_buffer:
		var lane: int = b[offset]
		acc = acc ^ (lane * PRIME64_5)
		acc = ((acc << 11) | unsrs(acc, 53)) * PRIME64_1
		offset += 1

	acc = acc ^ unsrs(acc, 33)
	acc = acc * PRIME64_2
	acc = acc ^ unsrs(acc, 29)
	acc = acc * PRIME64_3
	acc = acc ^ unsrs(acc, 32)
	return acc

static func test_xxHash64():
	assert(xxHash64("a".to_ascii_buffer()) == 3104179880475896308)
	assert(xxHash64("asdfghasdfghasdfghasdfghasdfghasdfghasdfghasdfghasdfghasdfghasdfghasdfgh".to_ascii_buffer()) == -3292477735350538661)
	assert(xxHash64(PackedByteArray().duplicate()) == -1205034819632174695)
