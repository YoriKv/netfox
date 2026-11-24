extends VestTest

# A client receiving, per rollback loop of the server, only the newest
# authoritative state of each node (netfox/rollback/send_newest_state_only)
# against receiving the state of every tick the server made authoritative

func get_suite_name() -> String:
	return "Newest state only"

const SERVER := 2
const OTHER_CLIENT := 4

var remote: Node3D
var remote_input: Node
var own: OwnNode
var own_input: Node

func before_case(__) -> void:
	Vest.get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	reset_session()

	# Another client's node, drawn here, and our own, both of the server's state
	remote_input = await add_node(Node.new())
	remote_input.set_multiplayer_authority(OTHER_CLIENT)
	remote = await add_node(RemoteNode.new())
	remote.set_multiplayer_authority(SERVER)
	own_input = await add_node(OwnInput.new())
	own = await add_node(OwnNode.new())
	own.set_multiplayer_authority(SERVER)

	for node in [remote, own]:
		RollbackSimulationServer.register(node._rollback_tick)
		NetworkHistoryServer.register_rollback_state(node, ^"position")
	RollbackSimulationServer.register_rollback_input_for(remote, remote_input)
	RollbackSimulationServer.register_rollback_input_for(own, own_input)
	NetworkHistoryServer.register_rollback_input(own_input, ^"speed")

func after_case(__) -> void:
	NetworkRollback._resimulate_on_remote_state = true
	for node in [remote, own, remote_input, own_input]:
		RollbackSimulationServer.deregister_node(node)
		NetworkHistoryServer.deregister(node)
		NetworkSynchronizationServer.deregister(node)
		node.queue_free()
	reset_session()

func suite() -> void:
	for resimulate in [true, false]:
		define("resimulate on remote state %s" % ["on" if resimulate else "off"], func():
			test("should leave the owner's own node as every tick would, from the newest own state on", func():
				for seed in range(1, 9):
					var session := server_session(seed, 60)
					var every := run_session(session[0], resimulate)
					var newest := run_session(session[1], resimulate)

					for loop in every.size():
						var from := newest_before(session, loop, "own")
						expect_equal(newest[loop][0].slice(from), every[loop][0].slice(from), "Seed %d, loop %d" % [seed, loop])
			)

			test("should leave a drawn node as every tick would from the newest state on, the newest before it", func():
				for seed in range(11, 19):
					var session := server_session(seed, 60)
					_rollback_ticks.clear()
					var every := run_session(session[0], resimulate)
					var newest := run_session(session[1], resimulate)

					for loop in every.size():
						var from := newest_before(session, loop, "remote")
						expect_equal(newest[loop][1].slice(from), every[loop][1].slice(from), "Seed %d, loop %d" % [seed, loop])
					var received := received_by_tick(session[1].slice(0, -1), newest.back()[1].size())
					var start := NetworkRollback.history_start + 1 # The oldest tick kept
					expect_equal(newest.back()[1].slice(start), received.slice(start), "Seed %d: each tick the newest state received at or before it" % [seed])
					expect(_rollback_ticks[1] <= _rollback_ticks[0], "Seed %d: no more rollback ticks" % [seed])
			)
		)

# Session ---------------------------------------------------------------------

var _rollback_ticks := [] # rollback ticks run per session

# The states a client receives in each loop of a server session: [every tick,
# newest only, the newest authoritative tick per node after each loop], the
# first two a list per loop of [ticks the loop runs, [[node name, tick,
# position], ...]]. The server makes each node's ticks authoritative up
# to its owner's input, which lags by 1 to 6 ticks and arrives in bursts; the
# own node's state now and then differs from the client's prediction, the
# remote node moves or rests out of the own node's reach
func server_session(seed: int, loops: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var truth := { "own": [Vector3.ZERO], "remote": [Vector3(5, 0, 0)] }
	var newest := { "own": 0, "remote": 0 }
	var every := []
	var newest_only := []
	var newest_ticks := []
	var tick := 0
	for loop in loops:
		var ticks := 2 if rng.randf() < 0.2 else 1
		tick += ticks
		for name in truth:
			var values := truth[name] as Array
			while values.size() <= tick:
				var last := values.back() as Vector3
				if name == "own":
					values.append(last + Vector3(1, 0, 0) + (Vector3(rng.randi_range(1, 4), 0, 0) if rng.randf() < 0.1 else Vector3.ZERO))
				else:
					values.append(last if rng.randf() < 0.3 else Vector3(rng.randi_range(5, 9), 0, rng.randi_range(0, 3)))

		var every_states := []
		var newest_states := []
		for name in truth:
			var values := truth[name] as Array
			var to := clampi(tick - rng.randi_range(1, 6), newest[name], tick)
			for state_tick in range(newest[name] + 1, to + 1):
				# A diff state sends a tick only if it changed
				if values[state_tick] != values[state_tick - 1]:
					every_states.append([name, state_tick, values[state_tick]])
			if to > newest[name] and values[to] != values[newest[name]]:
				newest_states.append([name, to, values[to]])
			newest[name] = to
		every.append([ticks, every_states])
		newest_only.append([ticks, newest_states])
		newest_ticks.append(newest.duplicate())
	return [every, newest_only, newest_ticks]

# The newest authoritative tick of [param name] the server had when the client
# ran [param loop]: the states of the loops before it arrived. Unsent if it
# held what was sent before
func newest_before(session: Array, loop: int, name: String) -> int:
	return 0 if loop == 0 else session[2][loop - 1][name]

# Runs [param events] as a client would, a tick loop each, with the states
# received after it. Returns per loop [own positions, remote positions], what
# each tick restores
func run_session(events: Array, resimulate: bool) -> Array:
	reset_session()
	NetworkRollback._resimulate_on_remote_state = resimulate
	own.position = Vector3.ZERO
	remote.position = Vector3(5, 0, 0)
	for node in [remote, own]:
		NetworkHistoryServer.push_rollback_state(node, 0)

	var result := []
	var rollback_ticks := 0
	var notify := func(): NetworkRollback.notify_resimulation_start(_loop_first_tick)
	NetworkRollback.before_loop.connect(notify)
	for event in events:
		_loop_first_tick = NetworkTime.tick
		for i in event[0] as int:
			NetworkHistoryServer._record_rollback_input(NetworkTime.tick)
			NetworkTime._tick += 1
		NetworkRollback._rollback()
		rollback_ticks += NetworkRollback.loop_to - NetworkRollback.loop_from
		var ticks := range(0, NetworkTime.tick + 1)
		result.append([values_of(own, ticks), values_of(remote, ticks)])

		for state in event[1]:
			var node: Node = own if state[0] == "own" else remote
			NetworkSynchronizationServer.inject_rollback_state(node, state[1], { ^"position": state[2] })
	NetworkRollback.before_loop.disconnect(notify)
	_rollback_ticks.append(rollback_ticks)
	return result

var _loop_first_tick := 0

# What each tick restores of the remote node with [param events] received:
# the newest state received at or before it
func received_by_tick(events: Array, ticks: int) -> Array:
	var received := {}
	for event in events:
		for state in event[1]:
			if state[0] == "remote":
				received[state[1]] = state[2]
	var result := []
	var latest := Vector3(5, 0, 0)
	for tick in ticks:
		latest = received.get(tick, latest)
		result.append(latest)
	return result

func reset_session() -> void:
	NetworkRollback.reset()
	NetworkHistoryServer.reset()
	RollbackSimulationServer.reset()
	NetworkSynchronizationServer.reset()
	NetworkMocks.set_tick(0, 0)

# What each of [param ticks] restores of [param node], null before its history
func values_of(node: Node, ticks: Array) -> Array:
	return ticks.map(func(tick):
		var snapshot := NetworkHistoryServer._rb_state_history.get_latest_snapshot(tick, node)
		return snapshot.get_value(^"position") if snapshot else null)

func add_node(node: Node) -> Node:
	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready
	return node

# Moves if ever simulated, which a client must not do
class RemoteNode extends Node3D:
	func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
		position.z += 100

# Moves a unit a tick, as the server's own node does unless it says otherwise
class OwnNode extends Node3D:
	func _rollback_tick(_delta: float, _tick: int, _is_fresh: bool) -> void:
		position.x += 1

class OwnInput extends Node:
	var speed := 1.0
