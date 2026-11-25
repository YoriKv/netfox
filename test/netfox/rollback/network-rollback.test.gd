extends VestTest

func get_suite_name() -> String:
	return "NetworkRollback"

var network_rollback: _NetworkRollback
var mutated_node: Node

func before_case(__):
	network_rollback = _NetworkRollback.new()
	mutated_node = Node.new()

func after_case(__):
	NetworkMocks.set_tick(0, 0)
	NetworkHistoryServer.reset()
	RollbackSimulationServer.reset()
	network_rollback.queue_free()
	mutated_node.queue_free()

func suite() -> void:
	define("mutate()", func():
		test("should be mutated after", func():
			# Given
			network_rollback.mutate(mutated_node, 8)

			# When + Then
			expect(network_rollback.is_mutated(mutated_node, 10))
			expect_not(network_rollback.is_just_mutated(mutated_node, 10))
		)

		test("should just be mutated", func():
			# Given
			network_rollback.mutate(mutated_node, 8)

			# When + Then
			expect(network_rollback.is_mutated(mutated_node, 8))
			expect(network_rollback.is_just_mutated(mutated_node, 8))
		)

		test("should not be mutated after", func():
			# Given
			network_rollback.mutate(mutated_node, 8)

			# When + Then
			expect_not(network_rollback.is_mutated(mutated_node, 4))
			expect_not(network_rollback.is_just_mutated(mutated_node, 4))
		)

		test("unknown should not be mutated", func():
			# Given nothing

			# Then
			expect_not(network_rollback.is_mutated(mutated_node, 8))
			expect_not(network_rollback.is_just_mutated(mutated_node, 8))
		)
	)

	define("reset()", func():
		test("should start over from tick 0", func():
			# Given
			network_rollback._tick = 500
			network_rollback._earliest_input = 498
			network_rollback._earliest_state = 499
			network_rollback.mutate(mutated_node, 500)

			# When
			network_rollback.reset()

			# Then
			expect_equal(network_rollback.tick, 0)
			expect_not(network_rollback.is_mutated(mutated_node, 500))
			expect_equal(network_rollback._earliest_input, -1)
			expect_equal(network_rollback._earliest_state, -1)
		)
	)

	define("loop range", func():
		test("should expose rollback range", func():
			network_rollback._rollback_from = 3
			network_rollback._rollback_to = 7

			expect_equal(network_rollback.loop_from, 3)
			expect_equal(network_rollback.loop_to, 7)
		)
	)

	define("debug resimulation", func():
		test("should resimulate at least the configured ticks", func():
			# Given
			NetworkMocks.set_network_tick(100)
			network_rollback._debug_resimulate_ticks = 8

			# When
			network_rollback._rollback()

			# Then
			expect_equal(network_rollback._rollback_from, 92)
			expect_equal(network_rollback._rollback_to, 100)
		)

		test("should keep an earlier start", func():
			# Given
			NetworkMocks.set_network_tick(100)
			network_rollback._debug_resimulate_ticks = 8
			network_rollback.before_loop.connect(func():
				network_rollback.notify_resimulation_start(80)
			)

			# When
			network_rollback._rollback()

			# Then
			expect_equal(network_rollback._rollback_from, 80)
		)

		test("should resimulate one tick by default", func():
			# Given
			NetworkMocks.set_network_tick(100)

			# When
			network_rollback._rollback()

			# Then
			expect_equal(network_rollback._rollback_from, 99)
		)
	)

	define("multi-tick loop", func():
		test("should simulate each tick of the loop once, in order, without remote input or state", func():
			# Given a node whose input this peer owns
			Vest.get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
			NetworkRollback.reset()
			NetworkMocks.set_tick(100, 0)
			var input := await add_node(TickInput.new())
			var subject := await add_node(TickRecorder.new())
			RollbackSimulationServer.register(subject._rollback_tick)
			RollbackSimulationServer.register_rollback_input_for(subject, input)
			NetworkHistoryServer.register_rollback_input(input, ^"value")
			NetworkHistoryServer.register_rollback_state(subject, ^"position")

			# When a loop runs three ticks, then a loop runs one
			run_tick_loop(3)
			run_tick_loop(1)

			# Then
			expect_equal(subject.ticks, [100, 101, 102, 103])

			for node in [subject, input]:
				RollbackSimulationServer.deregister_node(node)
				NetworkHistoryServer.deregister(node)
				node.queue_free()
			NetworkRollback.reset()
		)

		test("reset should forget the loop's first tick", func():
			# Given
			network_rollback._after_tick(40)

			# When
			network_rollback.reset()
			NetworkMocks.set_network_tick(100)
			network_rollback._rollback()

			# Then
			expect_equal(network_rollback._rollback_from, 99)
		)
	)

	define("_handle_tick_jump()", func():
		test("should advance the earliest valid history tick", func():
			# Given
			network_rollback._history_floor = 8

			# When
			network_rollback._handle_tick_jump(120)

			# Then
			expect_equal(network_rollback._history_floor, 120)
		)

		test("should never move the history floor backwards", func():
			# Given
			network_rollback._history_floor = 120

			# When
			network_rollback._handle_tick_jump(80)

			# Then
			expect_equal(network_rollback._history_floor, 120)
		)

		test("reset should clear the history floor", func():
			# Given
			network_rollback._history_floor = 120

			# When
			network_rollback.reset()

			# Then
			expect_equal(network_rollback._history_floor, 0)
		)

		test("should clamp a rollback range to the first tick after a gap", func():
			# Given
			NetworkMocks.set_network_tick(120)
			network_rollback._handle_tick_jump(120)
			network_rollback.before_loop.connect(func():
				network_rollback.notify_resimulation_start(1)
			)

			# When
			network_rollback._rollback()

			# Then
			expect_equal(network_rollback._rollback_from, 120)
			expect_equal(network_rollback._rollback_to, 120)
		)
	)

# Runs a tick loop of [param ticks] ticks as NetworkTime does, without its
# signals: each tick's input recorded, then the rollback loop
func run_tick_loop(ticks: int) -> void:
	for i in ticks:
		NetworkRollback._after_tick(NetworkTime.tick)
		NetworkTime._tick += 1
	NetworkRollback._rollback()

func add_node(node: Node) -> Node:
	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready
	return node

class TickInput extends Node:
	var value := 1

# Notes each tick it is simulated at
class TickRecorder extends Node3D:
	var ticks: Array[int] = []

	func _rollback_tick(_delta: float, tick: int, _is_fresh: bool) -> void:
		ticks.append(tick)
