extends VestTest

func get_suite_name() -> String:
	return "NetworkHistoryServer"

var servers: TestingServers
var subject: StateNode

func before_case(__) -> void:
	# Makes sure local peer is 1, otherwise identifiers get random local IDs
	Vest.get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	NetworkRollback.reset()
	NetworkMocks.set_tick(0, 0)
	servers = await TestingServers.create()
	subject = await create_subject()

func after_case(__) -> void:
	NetworkRollback.reset()
	NetworkMocks.set_tick(0, 0)
	servers.queue_free()
	NetworkHistoryServer.deregister(subject)
	RollbackLivenessServer.deregister(subject)
	subject.queue_free()

func suite() -> void:
	define("_merge_rollback_state()", func():
		test("should overwrite auth state for same tick", func():
			var node := await get_node()
			var history_server := servers.history_server()

			var baseline := _Snapshot.of(0, [
				[node, "position", Vector3.ZERO]
			], [node])
			var initial := _Snapshot.of(1, [
				[node, "position", Vector3.ZERO]
			], [node])
			var corrected := _Snapshot.of(1, [
				[node, "position", Vector3.ONE]
			], [node])

			history_server._merge_rollback_state(baseline)
			history_server._merge_rollback_state(initial)
			expect_true(history_server._merge_rollback_state(corrected))

			var current := history_server._get_rollback_state_snapshot(1)
			expect_equal(current, corrected)

			var diff := _Snapshot.make_patch(history_server._get_rollback_state_snapshot(0), current)
			expect_equal(diff, _Snapshot.of(1, [
				[node, "position", Vector3.ONE]
			], [node]))
		)

		test("should drop snapshots from before a skipped tick range", func():
			var history_server := servers.history_server()
			var stale := _Snapshot.of(20, [
				[subject, "position", Vector3.ONE]
			], [subject])
			NetworkMocks.set_network_tick(120)
			NetworkRollback._handle_tick_jump(120)

			expect_not(history_server._merge_rollback_state(stale))
			expect_null(history_server._get_rollback_state_snapshot(20))
			expect_equal(history_server.get_latest_state_tick_for([subject], 120), -1)
		)
	)

	define("on_correction", func():
		test("should report differing properties of a locally simulated node", func():
			var node := await get_node()
			var input := await get_node()
			RollbackSimulationServer.register_rollback_input_for(node, input)
			var corrections := record_corrections()
			var history_server := servers.history_server()
			var corrections_before := NetworkPerformance.get_corrections_total()

			# Recorded as predicted, then received from the server
			history_server._rb_state_history.set_property(4, node, ^"position", Vector3.ZERO)
			history_server._rb_state_history.set_property(4, node, ^"scale", Vector3.ONE)
			history_server._merge_rollback_state(_Snapshot.of(4, [
				[node, ^"position", Vector3.UP],
				[node, ^"scale", Vector3.ONE]
			], [node]))

			expect_equal(corrections, [[node, 4, { ^"position": [Vector3.ZERO, Vector3.UP] }]])
			expect_equal(NetworkPerformance.get_corrections_total() - corrections_before, 1)

			disconnect_corrections()
			RollbackSimulationServer.deregister_node(node)
			node.queue_free()
			input.queue_free()
		)

		test("should not report matching state", func():
			var node := await get_node()
			var corrections := record_corrections()
			var history_server := servers.history_server()

			history_server._rb_state_history.set_property(4, node, ^"position", Vector3.UP)
			history_server._merge_rollback_state(_Snapshot.of(4, [[node, ^"position", Vector3.UP]], [node]))

			expect_empty(corrections)

			disconnect_corrections()
			node.queue_free()
		)

		test("should not report a node simulated elsewhere", func():
			var node := await get_node()
			var input := await get_node()
			input.set_multiplayer_authority(2)
			RollbackSimulationServer.register_rollback_input_for(node, input)
			var corrections := record_corrections()
			var history_server := servers.history_server()
			var corrections_before := NetworkPerformance.get_corrections_total()

			history_server._rb_state_history.set_property(4, node, ^"position", Vector3.ZERO)
			history_server._merge_rollback_state(_Snapshot.of(4, [[node, ^"position", Vector3.UP]], [node]))

			expect_empty(corrections)
			expect_equal(NetworkPerformance.get_corrections_total(), corrections_before)

			disconnect_corrections()
			RollbackSimulationServer.deregister_node(node)
			node.queue_free()
			input.queue_free()
		)

		test("should report a node simulated elsewhere with prediction", func():
			var node := await get_node()
			var input := await get_node()
			input.set_multiplayer_authority(2)
			RollbackSimulationServer.register_rollback_input_for(node, input)
			RollbackSimulationServer.set_prediction_enabled_for(node, true)
			var corrections := record_corrections()
			var history_server := servers.history_server()

			history_server._rb_state_history.set_property(4, node, ^"position", Vector3.ZERO)
			history_server._merge_rollback_state(_Snapshot.of(4, [[node, ^"position", Vector3.UP]], [node]))

			expect_equal(corrections.size(), 1)

			disconnect_corrections()
			RollbackSimulationServer.deregister_node(node)
			node.queue_free()
			input.queue_free()
		)

		test("should not report a tick without recorded state", func():
			var node := await get_node()
			var corrections := record_corrections()
			var history_server := servers.history_server()

			history_server._rb_state_history.set_property(3, node, ^"position", Vector3.ZERO)
			history_server._merge_rollback_state(_Snapshot.of(4, [[node, ^"position", Vector3.UP]], [node]))

			expect_empty(corrections)

			disconnect_corrections()
			node.queue_free()
		)
	)

	define("partial states", func():
		test("should keep its own record of a property not received", func():
			var node := await get_node()
			var history_server := servers.history_server()
			history_server._rb_state_history.set_property(4, node, ^"position", Vector3.ZERO)
			history_server._rb_state_history.set_property(4, node, ^"scale", Vector3.ONE * 3)

			history_server._merge_rollback_state(_Snapshot.of(4, [[node, ^"position", Vector3.UP]], [node]))

			expect_equal(history_server.get_rollback_state_at(node, 4), {
				^"position": Vector3.UP, ^"scale": Vector3.ONE * 3
			})
			node.queue_free()
		)

		test("should carry nothing into a gap once the tick before it left the history", func():
			var node := await get_node()
			var history_server := servers.history_server()
			# Recorded every tick, then a gap of 60 ticks, then 4 ticks: tick 63 is out
			var ticks := range(0, 64) + range(124, 128)
			for tick in ticks:
				history_server._rb_state_history.set_property(tick, node, ^"scale", Vector3.ONE * tick)
			NetworkMocks.set_network_tick(128)

			# A state for a tick of the gap
			history_server._merge_rollback_state(_Snapshot.of(70, [[node, ^"position", Vector3.UP]], [node]))

			expect_equal(history_server.get_rollback_state_at(node, 70), { ^"position": Vector3.UP },
				"No tick at or before it is held to carry from")
			node.queue_free()
		)
	)

	define("push_rollback_state()", func():
		test("should create a snapshot at spawn tick", func():
			subject.tracked_value = 42
			NetworkHistoryServer.register_rollback_state(subject, ^"tracked_value")

			NetworkHistoryServer.push_rollback_state(subject, 5)

			var snapshot := NetworkHistoryServer._get_rollback_state_snapshot(5)
			expect_not_null(snapshot)
			expect(snapshot.has_property(subject, ^"tracked_value"))
			expect_equal(snapshot.get_property(subject, ^"tracked_value"), 42)
			expect_equal(NetworkHistoryServer.get_latest_state_tick_for([subject], 5), 5)
		)

		test("should mark local authority as auth", func():
			NetworkHistoryServer.register_rollback_state(subject, ^"tracked_value")

			NetworkHistoryServer.push_rollback_state(subject, 7)

			var snapshot := NetworkHistoryServer._get_rollback_state_snapshot(7)
			expect_not_null(snapshot)
			expect(snapshot.is_auth(subject))
		)

		test("should mark remote authority as non-auth", func():
			subject.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_state(subject, ^"tracked_value")

			NetworkHistoryServer.push_rollback_state(subject, 7)

			var snapshot := NetworkHistoryServer._get_rollback_state_snapshot(7)
			expect_not_null(snapshot)
			expect_not(snapshot.is_auth(subject))
		)

		test("should not create history before spawn tick", func():
			NetworkHistoryServer.register_rollback_state(subject, ^"tracked_value")

			NetworkHistoryServer.push_rollback_state(subject, 6)

			expect_equal(NetworkHistoryServer.get_latest_state_tick_for([subject], 5), -1)
		)
	)

	define("_record_rollback_state()", func():
		test("should skip subjects not alive at previous tick", func():
			subject.tracked_value = 10
			NetworkHistoryServer.register_rollback_state(subject, ^"tracked_value")
			RollbackLivenessServer.register(
				subject,
				subject._rollback_spawn,
				subject._rollback_despawn,
				subject._rollback_destroy,
				5
			)
			NetworkHistoryServer.push_rollback_state(subject, 5)
			subject.tracked_value = 99

			NetworkHistoryServer._record_rollback_state(5)

			var spawn_snapshot := NetworkHistoryServer._get_rollback_state_snapshot(5)
			expect_not_null(spawn_snapshot)
			expect_equal(spawn_snapshot.get_property(subject, ^"tracked_value"), 10)
			expect_equal(NetworkHistoryServer.get_latest_state_tick_for([subject], 5), 5)

			subject.tracked_value = 11
			NetworkHistoryServer._record_rollback_state(6)

			var post_spawn_snapshot := NetworkHistoryServer._get_rollback_state_snapshot(6)
			expect_not_null(post_spawn_snapshot)
			expect(post_spawn_snapshot.has_property(subject, ^"tracked_value"))
			expect_equal(post_spawn_snapshot.get_property(subject, ^"tracked_value"), 11)
			expect_equal(NetworkHistoryServer.get_latest_state_tick_for([subject], 6), 6)
		)
	)
	define("get_rollback_input_at()", func():
		test("should return recorded", func():
			var node := await get_node()
			var history_server := servers.history_server()
			history_server.register_rollback_input(node, ^"position")
			node.position = Vector3.ONE

			history_server._record_rollback_input(4)

			expect_equal(history_server.get_rollback_input_at(node, 4), { ^"position": Vector3.ONE })
			expect_empty(history_server.get_rollback_input_at(node, 5))
			node.queue_free()
		)
	)

	define("get_rollback_state_at()", func():
		test("should return authoritative", func():
			var node := await get_node()
			var history_server := servers.history_server()

			history_server._merge_rollback_state(_Snapshot.of(3, [[node, "position", Vector3.ONE]], [node]))

			expect_equal(history_server.get_rollback_state_at(node, 3), { ^"position": Vector3.ONE })
			node.queue_free()
		)

		test("should be empty for non-authoritative", func():
			var node := await get_node()
			var history_server := servers.history_server()

			history_server._merge_rollback_state(_Snapshot.of(3, [[node, "position", Vector3.ONE]], []))

			expect_empty(history_server.get_rollback_state_at(node, 3))
			expect_empty(history_server.get_rollback_state_at(node, 4))
			node.queue_free()
		)
	)

	define("reset()", func():
		test("should record early ticks after reset", func():
			var history_server := servers.history_server()
			history_server.register_rollback_state(subject, ^"tracked_value")

			# Previous session ends way past the history size
			history_server._record_rollback_state(500)
			history_server.reset()

			# Next session starts from the beginning
			subject.tracked_value = 7
			history_server._record_rollback_state(5)

			var snapshot := history_server._get_rollback_state_snapshot(5)
			expect_not_null(snapshot)
			expect_equal(snapshot.get_property(subject, ^"tracked_value"), 7)
			expect_equal(history_server.get_latest_state_tick_for([subject], 5), 5)
			expect_null(history_server._get_rollback_state_snapshot(500))
		)
	)

var _correction_handler: Callable

# Each correction emitted, as [node, tick, properties], until disconnected
func record_corrections() -> Array:
	var result := []
	_correction_handler = func(node: Node, tick: int, properties: Dictionary):
		result.append([node, tick, properties])
	NetworkRollback.on_correction.connect(_correction_handler)
	return result

func disconnect_corrections() -> void:
	NetworkRollback.on_correction.disconnect(_correction_handler)

func create_subject() -> StateNode:
	var node := StateNode.new()
	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready
	return node

class StateNode extends Node:
	var tracked_value := 0
	var spawns := 0
	var despawns := 0
	var destroyed := false

	func _rollback_spawn() -> void:
		spawns += 1

	func _rollback_despawn() -> void:
		despawns += 1

	func _rollback_destroy() -> void:
		destroyed = true

func get_node() -> Node3D:
	var node := Node3D.new()

	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready

	return node
