extends VestTest

func get_suite_name() -> String:
	return "NetworkPerformance"

var performance: _NetworkPerformance

func before_case(__):
	performance = _NetworkPerformance.new()

func after_case(__):
	NetworkMocks.set_tick(0, 0)
	performance.free()

func suite() -> void:
	define("input lateness", func():
		test("should report the last window per peer", func():
			NetworkMocks.set_network_tick(10)
			performance.push_input_lateness(2, 3)
			performance.push_input_lateness(2, 5)
			performance.push_input_lateness(2, -2)
			performance.push_input_lateness(3, 1)
			performance._after_tick_loop()

			expect_equal(performance.get_input_lateness_mean(2), 2.)
			expect_equal(performance.get_input_lateness_max(2), 5)
			expect_equal(performance.get_input_lateness_max(3), 1)
			expect_equal(performance.get_input_lateness_max_all(), 5)
			expect_equal(performance.get_input_lateness_mean_all(), 7. / 4.)
		)

		test("should keep a window until it ends", func():
			NetworkMocks.set_network_tick(10)
			performance.push_input_lateness(2, 3)
			performance._after_tick_loop()

			performance.push_input_lateness(2, 9)
			NetworkMocks.set_network_tick(11)
			performance._after_tick_loop()
			expect_equal(performance.get_input_lateness_max(2), 3)

			NetworkMocks.set_network_tick(10 + NetworkTime.tickrate)
			performance._after_tick_loop()
			expect_equal(performance.get_input_lateness_max(2), 9)
		)

		test("should report nothing for a silent peer", func():
			NetworkMocks.set_network_tick(10)
			performance._after_tick_loop()

			expect_empty(performance.get_input_lateness_peers())
			expect_equal(performance.get_input_lateness_mean(2), 0.)
			expect_equal(performance.get_input_lateness_max(2), 0)
		)
	)

	define("corrections", func():
		test("should count per tick loop and in total", func():
			performance.push_corrections(2)
			performance.push_corrections(1)
			performance._after_tick_loop()
			expect_equal(performance.get_corrections(), 3)

			performance._after_tick_loop()
			expect_equal(performance.get_corrections(), 0)
			expect_equal(performance.get_corrections_total(), 3)
		)
	)

	define("command bytes", func():
		test("should count bytes sent per command", func():
			var command_server := TestingCommandServer.new()
			var command := command_server.register_command(func(_sender, _data): pass)

			command.send(PackedByteArray([1, 2, 3]), 2)
			command.send(PackedByteArray([4]), 3)

			expect_equal(command.get_sent_bytes(), 4)
			expect_equal(command.get_sent_packets(), 2)
			command_server.free()
		)
	)
