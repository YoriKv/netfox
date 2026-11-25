extends VestTest

func get_suite_name() -> String:
	return "HistoryBuffer"

func suite() -> void:
	var empty_buffer := _HistoryBuffer.new()
	var filled_buffer := _HistoryBuffer.of(16, { 2: "foo", 4: "bar", 8: "baz" })

	define("get latest", func():
		test("should not have latest if empty", func():
			expect_not(empty_buffer.has_at(16))
			expect_not(empty_buffer.has_latest_at(16))
		)

		test("should not have latest out of bounds", func():
			expect_not(filled_buffer.has_latest_at(0))
		)

		test("should return self on known item", func():
			expect_equal(filled_buffer.get_latest_index_at(2), 2)
			expect_equal(filled_buffer.get_latest_index_at(4), 4)
			expect_equal(filled_buffer.get_latest_index_at(8), 8)
		)

		test("should return latest on unknown", func():
			expect_equal(filled_buffer.get_latest_index_at(3), 2)
			expect_equal(filled_buffer.get_latest_index_at(5), 4)
			expect_equal(filled_buffer.get_latest_index_at(9), 8)
		)
	)

	define("set_at()", func():
		test("should set behind tail", func():
			var buffer := filled_buffer.duplicate()
			buffer.set_at(1, 4)
			expect(buffer.has_at(1))
		)

		test("should not set behind limit", func():
			var buffer := filled_buffer.duplicate()
			buffer.set_at(-8, 4)
			expect_not(buffer.has_at(-8))
		)

		test("should update prev buffer if in bounds", func():
			var buffer := filled_buffer.duplicate()
			buffer.set_at(6, "quoo")
			expect_not(buffer.has_at(7))
			expect(buffer.has_latest_at(7))
			expect_equal(buffer.get_latest_at(7), "quoo")
		)

		test("should update prev buffer if after head", func():
			var buffer := filled_buffer.duplicate()
			buffer.set_at(14, "quoo")
			expect_not(buffer.has_at(11))
			expect(buffer.has_latest_at(11))
			expect_equal(buffer.get_latest_at(11), "baz")
		)

		test("should jump if way after head", func():
			var buffer := filled_buffer.duplicate()
			buffer.set_at(130, "quoo")
			expect_not(buffer.has_at(8))
			expect_not(buffer.has_latest_at(8))
			expect_equal(buffer.size(), 1)
		)
	)

	define("values()", func():
		test("should return empty", func():
			var buffer := empty_buffer.duplicate()
			expect_equal(buffer.values(), [])
		)

		test("should return empty after clear", func():
			var buffer := filled_buffer.duplicate()
			buffer.clear()
			expect_equal(buffer.values(), [])
		)

		test("should skip gaps", func():
			var buffer := _HistoryBuffer.of(16, { 2: "hello", 4: "world", 15: "!"})
			expect_equal(buffer.values(), ["hello", "world", "!"])
		)
	)

	define("trim()", func():
		test("should remove from a tick on", func():
			var buffer := _HistoryBuffer.of(16, { 2: "a", 4: "b", 5: "c", 7: "d" })
			buffer.trim(5)
			expect_equal(buffer.values(), ["a", "b"])
			expect_not(buffer.has_at(5))
			expect_equal(buffer.get_latest_index_at(10), 4)
			expect_equal(buffer.get_latest_at(10), "b")

			buffer.set_at(8, "e")
			expect_equal(buffer.values(), ["a", "b", "e"])
			expect_equal(buffer.get_latest_at(6), "b")
		)

		test("should empty from its first tick", func():
			var buffer := _HistoryBuffer.of(16, { 2: "a", 4: "b" })
			buffer.trim(1)
			expect(buffer.is_empty())
		)

		test("should end at the last item before a gap it cuts", func():
			var buffer := _HistoryBuffer.of(16, { 2: "a", 4: "b" })
			buffer.trim(4)
			expect_equal(buffer.get_latest_index(), 2)
			expect_equal(buffer.get_latest_index_at(10), 2)
			expect_equal(buffer.get_latest_at(10), "a")

			buffer.set_at(8, "e")
			expect_equal(buffer.values(), ["a", "e"])
			expect_equal(buffer.get_latest_at(6), "a")
		)
	)

	define("gaps", func():
		test("should not have latest in gap after skipping past capacity", func():
			var buffer := _HistoryBuffer.new(64)
			buffer.set_at(54, "foo")
			buffer.set_at(118, "bar")

			expect_not(buffer.has_latest_at(55))
			expect_equal(buffer.get_earliest_index(), 118)
			expect_equal(buffer.get_latest_at(118), "bar")
		)

		test("should not have latest in gap after pushing past capacity", func():
			var buffer := _HistoryBuffer.of(4, { 0: "foo", 3: "bar" })
			buffer.push("baz")

			expect_not(buffer.has_latest_at(1))
			expect_equal(buffer.get_earliest_index(), 3)
			expect_equal(buffer.values(), ["bar", "baz"])
		)

		test("should not have latest in gap after pop", func():
			var buffer := _HistoryBuffer.of(16, { 2: "foo", 4: "bar" })
			buffer.pop()

			expect_not(buffer.has_latest_at(3))
			expect_equal(buffer.get_earliest_index(), 4)
		)

		test("should always return the item of the latest tick it holds", func():
			# Random writes, pops and trims against a dictionary of what is held
			for seed in range(1, 9):
				if not _holds_latest(seed):
					return
			ok()
		)
	)

# Random writes, pops and trims of a buffer, checked after each against a
# dictionary of what it holds; fails and returns false on the first difference
func _holds_latest(seed: int) -> bool:
	var buffer := _HistoryBuffer.new(8)
	var held := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	var at := 0
	for i in 1024:
		var roll := rng.randf()
		if roll < 0.1 and buffer.is_not_empty():
			held.erase(buffer.get_earliest_index())
			buffer.pop()
		elif roll < 0.15 and buffer.is_not_empty():
			var from := rng.randi_range(buffer.get_earliest_index(), buffer.get_latest_index())
			buffer.trim(from)
			for tick in held.keys():
				if tick >= from:
					held.erase(tick)
		else:
			at += rng.randi_range(-4, 12)
			buffer.set_at(at, i)
			if buffer.get_at(at) == i:
				held[at] = i
		for tick in held.keys():
			if tick < buffer.get_earliest_index() or tick > buffer.get_latest_index():
				held.erase(tick)

		for idx in range(buffer.get_earliest_index() - 2, buffer.get_latest_index() + 3):
			var earlier := held.keys().filter(func(tick: int) -> bool: return tick <= idx)
			if buffer.has_latest_at(idx) != not earlier.is_empty():
				fail("Seed %d, step %d: has latest at %d is %s, holding %s" % [seed, i, idx, buffer.has_latest_at(idx), held])
				return false
			if earlier.is_empty():
				continue
			var expected: int = earlier.max()
			if buffer.get_latest_index_at(idx) != expected or buffer.get_latest_at(idx) != held[expected]:
				fail("Seed %d, step %d: latest at %d is @%d %s, expected @%d %s" % [seed, i, idx,
					buffer.get_latest_index_at(idx), buffer.get_latest_at(idx), expected, held[expected]])
				return false
	return true
