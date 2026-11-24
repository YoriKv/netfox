extends VestTest

# A received state of a node this peer does not simulate, with
# netfox/rollback/resimulate_on_remote_state off: it starts no resimulation,
# and every reader of the history sees what a full resimulation would leave

func get_suite_name() -> String:
	return "Remote state"

const SERVER := 2
const OTHER_CLIENT := 4

var remote: RemoteNode
var remote_input: Node
var own: OwnNode
var own_input: OwnInput

func before_case(__) -> void:
	# Makes sure local peer is 1, otherwise identifiers get random local IDs
	Vest.get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	reset_session()

	# Another client's node and our own, both of the server's state
	remote_input = await add_node(Node.new())
	remote_input.set_multiplayer_authority(OTHER_CLIENT)
	remote = await add_node(RemoteNode.new())
	remote.set_multiplayer_authority(SERVER)

	own_input = await add_node(OwnInput.new())
	own = await add_node(OwnNode.new())
	own.set_multiplayer_authority(SERVER)
	own.remote = remote

	for node in [remote, own]:
		RollbackSimulationServer.register(node._rollback_tick)
		NetworkHistoryServer.register_rollback_state(node, ^"position")
		NetworkHistoryServer.register_rollback_state(node, ^"scale")
	RollbackSimulationServer.register_rollback_input_for(remote, remote_input)
	RollbackSimulationServer.register_rollback_input_for(own, own_input)
	NetworkHistoryServer.register_rollback_input(own_input, ^"speed")

func after_case(__) -> void:
	NetworkRollback._resimulate_on_remote_state = true
	for node in [remote, own, remote_input, own_input]:
		RollbackSimulationServer.deregister_node(node)
		NetworkHistoryServer.deregister(node)
		NetworkSynchronizationServer.deregister(node)
		RollbackLivenessServer.deregister(node)
		node.queue_free()
	reset_session()

func suite() -> void:
	define("merging a state", func():
		test("should carry it to the ticks after it, starting no resimulation", func():
			NetworkRollback._resimulate_on_remote_state = false
			record_remote(range(0, 9), Vector3.ZERO)

			var resimulates := merge(5, remote, Vector3.ONE)

			expect_not(resimulates)
			expect_equal(remote_values(range(0, 9)), [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
				Vector3.ZERO, Vector3.ONE, Vector3.ONE, Vector3.ONE, Vector3.ONE])
			expect_equal(auth_ticks(remote, range(0, 9)), [5], "Carried copies stay non-authoritative")
			var tick_snapshot := NetworkHistoryServer._get_rollback_state_snapshot(7)
			expect_equal(tick_snapshot.get_property(remote, ^"position"), Vector3.ONE)
			expect_not(tick_snapshot.is_auth(remote))
		)

		test("should stop at the next authoritative state", func():
			NetworkRollback._resimulate_on_remote_state = false
			record_remote(range(0, 9), Vector3.ZERO)
			merge(6, remote, Vector3.UP)

			merge(3, remote, Vector3.ONE)

			expect_equal(remote_values(range(2, 9)), [Vector3.ZERO, Vector3.ONE, Vector3.ONE, Vector3.ONE,
				Vector3.UP, Vector3.UP, Vector3.UP])
			expect_equal(auth_ticks(remote, range(0, 9)), [3, 6])
		)

		test("should fill the ticks a loop skipped", func():
			NetworkRollback._resimulate_on_remote_state = false
			record_remote([0, 1, 4], Vector3.ZERO)

			merge(1, remote, Vector3.ONE)

			expect_equal(remote_values(range(0, 5)), [Vector3.ZERO, Vector3.ONE, Vector3.ONE, Vector3.ONE, Vector3.ONE])
			expect_not_null(NetworkHistoryServer._rb_state_history.get_snapshot(3, remote))
		)

		test("should skip ticks after which the node is dead", func():
			NetworkRollback._resimulate_on_remote_state = false
			record_remote(range(0, 9), Vector3.ZERO)
			RollbackLivenessServer.register(remote, func(): pass, func(): pass, func(): pass, 0)
			RollbackLivenessServer.despawn(remote, 5)

			merge(3, remote, Vector3.ONE)

			expect_equal(remote_values(range(3, 9)), [Vector3.ONE, Vector3.ONE, Vector3.ONE, Vector3.ONE,
				Vector3.ZERO, Vector3.ZERO], "Recording stops after the despawn tick")
		)

		test("should resimulate a node this peer simulates only if it changed", func():
			NetworkRollback._resimulate_on_remote_state = false
			NetworkHistoryServer._rb_state_history.set_property(4, own, ^"position", Vector3.ZERO)

			expect_not(merge(4, own, Vector3.ZERO), "Prediction was right")
			expect(merge(4, own, Vector3.ONE), "Prediction was wrong")
		)

		test("should resimulate on any change by default", func():
			record_remote(range(0, 9), Vector3.ZERO)

			expect(merge(5, remote, Vector3.ONE))
			expect_equal(remote_values([6]), [Vector3.ZERO], "The resimulation rewrites the ticks after it")
		)
	)

	define("against a full resimulation", func():
		test("should leave every tick restoring the newest full state received at or before it", func():
			for seed in range(1, 9):
				var events := random_session(seed, 48, false)
				var resimulated := run_session(events, true, false)
				var carried := run_session(events, false, false)

				for loop in resimulated.size():
					expect_equal(carried[loop], resimulated[loop], "Seed %d, loop %d" % [seed, loop])
				expect_equal(carried.back(), received_by_tick(events.slice(0, -1), 48), "Seed %d: the newest state at or before each tick" % [seed])
				expect(_rollback_ticks[false] < _rollback_ticks[true], "Seed %d: fewer rollback ticks" % [seed])
		)

		test("should match resimulating after each state, with diff states, multi-tick loops and own corrections", func():
			for seed in range(11, 19):
				var events := random_session(seed, 48, true)
				var resimulated := run_session(events, true, true)
				var carried := run_session(events, false, false)

				for loop in resimulated.size():
					expect_equal(carried[loop], resimulated[loop], "Seed %d, loop %d" % [seed, loop])
		)

		test("should run only what this peer's own nodes need", func():
			var events := random_session(3, 48, false)
			run_session(events, false, false)

			expect_equal(_loop_starts, range(0, 48), "The loop's own ticks, without own corrections")
		)
	)

# Session ---------------------------------------------------------------------

var _rollback_ticks := {} # setting value to rollback ticks run
var _loop_starts := []

# Events per tick loop: [ticks the loop runs, [[node name, tick, position, scale or null], ...]]
func random_session(seed: int, loops: int, varied: bool) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var result := []
	var tick := 0
	for loop in loops:
		var ticks := 2 if varied and rng.randf() < 0.2 else 1
		tick += ticks
		var states := []
		for i in rng.randi_range(0, 3):
			# In order, late, duplicated or older than one received
			var state_tick := clampi(tick - rng.randi_range(0, 12), 1, tick)
			var position := Vector3(rng.randi_range(0, 3), 0, 0)
			var scale = Vector3.ONE
			if varied:
				scale = Vector3.ONE * rng.randi_range(1, 3) if rng.randf() < 0.5 else null
			states.append(["remote", state_tick, position, scale])
			if rng.randf() < 0.2:
				states.append(["remote", state_tick, position, scale])
		if varied and rng.randf() < 0.3:
			states.append(["own", clampi(tick - rng.randi_range(1, 8), 1, tick), Vector3(rng.randi_range(0, 40), 0, 0), Vector3.ONE])
		result.append([ticks, states])
	return result

# Runs [param events] as a client would, a tick loop each, with the states
# received after it; with [param loop_per_state], resimulating after each state
# as well. Returns the remote node's history after each tick loop: what each
# tick restores, and its authoritative ticks
func run_session(events: Array, resimulate: bool, loop_per_state: bool) -> Array:
	reset_session()
	NetworkRollback._resimulate_on_remote_state = resimulate
	for node in [remote, own]:
		node.position = Vector3.ZERO
		node.scale = Vector3.ONE
		NetworkHistoryServer.push_rollback_state(node, 0)

	var result := []
	var rollback_ticks := 0
	_loop_starts.clear()
	var notify := func(): NetworkRollback.notify_resimulation_start(_loop_first_tick)
	NetworkRollback.before_loop.connect(notify)
	for event in events:
		_loop_first_tick = NetworkTime.tick
		for i in event[0] as int:
			NetworkHistoryServer._record_rollback_input(NetworkTime.tick)
			NetworkTime._tick += 1
		NetworkRollback._rollback()
		rollback_ticks += NetworkRollback.loop_to - NetworkRollback.loop_from
		_loop_starts.append(NetworkRollback.loop_from)
		result.append([remote_values(range(0, NetworkTime.tick + 1)), auth_ticks(remote, range(0, NetworkTime.tick + 1))])

		for state in event[1]:
			var node: Node = remote if state[0] == "remote" else own
			var values := { ^"position": state[2] }
			if state[3] != null:
				values[^"scale"] = state[3]
			NetworkSynchronizationServer.inject_rollback_state(node, state[1], values)
			if loop_per_state:
				NetworkRollback._rollback()
	NetworkRollback.before_loop.disconnect(notify)
	_rollback_ticks[resimulate] = rollback_ticks
	return result

var _loop_first_tick := 0

# What each tick restores with only full states received: the last one
# received for the newest tick at or before it
func received_by_tick(events: Array, last_tick: int) -> Array:
	var received := {}
	for event in events:
		for state in event[1]:
			if state[0] == "remote":
				received[state[1]] = state[2]
	var values := []
	var latest := Vector3.ZERO
	for tick in range(0, last_tick + 1):
		latest = received.get(tick, latest)
		values.append(latest)
	var ticks := received.keys()
	ticks.sort()
	return [values, ticks]

func reset_session() -> void:
	NetworkRollback.reset()
	NetworkHistoryServer.reset()
	RollbackSimulationServer.reset()
	NetworkSynchronizationServer.reset()
	NetworkMocks.set_tick(0, 0)

# Helpers ---------------------------------------------------------------------

func record_remote(ticks: Array, position: Vector3) -> void:
	for tick in ticks:
		NetworkHistoryServer._rb_state_history.set_property(tick, remote, ^"position", position)
		NetworkHistoryServer._rb_state_history.set_property(tick, remote, ^"scale", Vector3.ONE)

func merge(tick: int, node: Node, position: Vector3) -> bool:
	return NetworkHistoryServer._merge_rollback_state(_Snapshot.of(tick, [[node, ^"position", position]], [node]))

# The position restored at each of [param ticks], or the whole record with
# several properties
func remote_values(ticks: Array) -> Array:
	var result := []
	for tick in ticks:
		var snapshot := NetworkHistoryServer._rb_state_history.get_latest_snapshot(tick, remote)
		result.append(snapshot.get_value(^"position") if snapshot.get_value(^"scale") == Vector3.ONE else snapshot._data.duplicate())
	return result

func auth_ticks(node: Node, ticks: Array) -> Array:
	return ticks.filter(func(tick): return NetworkHistoryServer._rb_state_history.is_auth(tick, node))

func add_node(node: Node) -> Node:
	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready
	return node

# Moves if ever simulated, which a client must not do
class RemoteNode extends Node3D:
	func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
		position.z += 100

# Follows the remote node's restored pose
class OwnNode extends Node3D:
	var remote: Node3D

	func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
		position.x += 1
		position.y = remote.position.x

class OwnInput extends Node:
	var speed := 1.0
