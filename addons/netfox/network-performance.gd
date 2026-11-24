extends Node
class_name _NetworkPerformance

# @public class

const NETWORK_LOOP_DURATION_MONITOR: StringName = &"netfox/Network loop duration (ms)"
const ROLLBACK_LOOP_DURATION_MONITOR: StringName = &"netfox/Rollback loop duration (ms)"
const NETWORK_TICKS_MONITOR: StringName = &"netfox/Network ticks simulated"
const ROLLBACK_TICKS_MONITOR: StringName = &"netfox/Rollback ticks simulated"
const ROLLBACK_TICK_DURATION_MONITOR: StringName = &"netfox/Rollback tick duration (ms)"
const ROLLBACK_NODES_SIMULATED_MONITOR: StringName = &"netfox/Rollback nodes simulated"
const ROLLBACK_NODES_SIMULATED_PER_TICK_MONITOR: StringName = &"netfox/Rollback nodes simulated per tick (avg)"

const FULL_STATE_PROPERTIES_COUNT: StringName = &"netfox/Full state properties count"
const SENT_STATE_PROPERTIES_COUNT: StringName = &"netfox/Sent state properties count"
const SENT_STATE_PROPERTIES_RATIO: StringName = &"netfox/Sent state properties ratio"

const CORRECTIONS_MONITOR: StringName = &"netfox/Corrections"
const ROLLBACK_NODES_FRESH_MONITOR: StringName = &"netfox/Rollback nodes simulated fresh"
const ROLLBACK_NODES_NEW_INPUT_MONITOR: StringName = &"netfox/Rollback nodes simulated with new input"
const INPUT_LATENESS_MEAN_MONITOR: StringName = &"netfox/Input lateness mean (ticks)"
const INPUT_LATENESS_MAX_MONITOR: StringName = &"netfox/Input lateness max (ticks)"
const SENT_STATE_BYTES_MONITOR: StringName = &"netfox/Sent rollback state bytes"
const SENT_INPUT_BYTES_MONITOR: StringName = &"netfox/Sent input bytes"
const SENT_SYNC_STATE_BYTES_MONITOR: StringName = &"netfox/Sent sync state bytes"

var _network_loop_start: float = 0
var _network_loop_duration: float = 0

var _network_ticks: int = 0
var _network_ticks_accum: int = 0

var _rollback_loop_start: float = 0
var _rollback_loop_duration: float = 0

var _rollback_ticks: int = 0
var _rollback_ticks_accum: int = 0

var _rollback_nodes_simulated: int = 0
var _rollback_nodes_simulated_accum: int = 0

var _full_state_props: int = 0
var _full_state_props_accum: int = 0

var _sent_state_props: int = 0
var _sent_state_props_accum: int = 0

var _corrections: int = 0
var _corrections_accum: int = 0
var _corrections_total: int = 0

var _rollback_nodes_fresh: int = 0
var _rollback_nodes_fresh_accum: int = 0
var _rollback_nodes_new_input: int = 0
var _rollback_nodes_new_input_accum: int = 0

# Input lateness per peer, over windows of a second of ticks
var _input_lateness_accum := {} # peer to [sum, count, max] in the current window
var _input_lateness := {} # peer to [sum, count, max] in the last window
var _input_lateness_window_end: int = -1

# Bytes handed to NetworkCommandServer, per command kind
var _sent_bytes := {} # command kind to bytes sent in the last tick loop
var _sent_bytes_totals := {} # command kind to total bytes at the last tick loop

# Whether monitoring is enabled, cached
var _enabled: bool = false

static var _logger: NetfoxLogger = NetfoxLogger._for_netfox("NetworkPerformance")

## Check if performance monitoring is enabled.
## [br][br]
## By default, monitoring is only enabled in debug builds
## ( see [method OS.is_debug_build] ). [br]
## Can be forced on with the [code]netfox_perf[/code] feature tag. [br]
## Can be forced off with the [code]netfox_noperf[/code] feature tag.
func is_enabled() -> bool:
	if OS.has_feature("netfox_noperf"):
		return false

	if OS.has_feature("netfox_perf"):
		return true

	# This returns true in the editor too
	return OS.is_debug_build()

## Get time spent in the last network tick loop, in millisec.
## [br]
## Note that this also includes time spent in the rollback tick loop.
func get_network_loop_duration_ms() -> float:
	return _network_loop_duration * 1000

## Get the number of ticks simulated in the last network tick loop.
func get_network_ticks() -> int:
	return _network_ticks

## Get time spent in the last rollback tick loop, in millisec.
func get_rollback_loop_duration_ms() -> float:
	return _rollback_loop_duration * 1000

## Get the number of ticks resimulated in the last rollback tick loop.
func get_rollback_ticks() -> int:
	return _rollback_ticks

## Get the average amount of time spent in a rollback tick during the last
## rollback loop, in millisec.
func get_rollback_tick_duration_ms() -> float:
	return _rollback_loop_duration * 1000 / maxi(_rollback_ticks, 1)

## Get the number of nodes simulated during the last rollback loop.
func get_rollback_nodes_simulated() -> int:
	return _rollback_nodes_simulated

## Get the number of nodes simulated per tick on average during the last
## rollback loop.
func get_rollback_nodes_simulated_per_tick() -> float:
	return _rollback_nodes_simulated / maxf(1., _rollback_ticks)

func push_rollback_nodes_simulated(count: int) -> void:
	_rollback_nodes_simulated_accum += count

## Get the number of properties in the full state recorded during the last tick
## loop.
func get_full_state_props_count() -> int:
	return _full_state_props

## Get the number of properties actually sent during the last tick loop.
func get_sent_state_props_count() -> int:
	return _sent_state_props

## Get the ratio of sent properties count to full state properties count.
##
## See [member get_full_state_props_count][br]
## See [member get_sent_state_props_count]
func get_sent_state_props_ratio() -> float:
	return _sent_state_props / maxf(1., _full_state_props)

func push_full_state(state: Dictionary) -> void:
	_full_state_props_accum += state.size()

func push_full_state_props(count: int) -> void:
	_full_state_props_accum += count

func push_full_state_broadcast(state: Dictionary) -> void:
	_full_state_props_accum += state.size() * (multiplayer.get_peers().size() - 1)

func push_sent_state(state: Dictionary) -> void:
	_sent_state_props_accum += state.size()

func push_sent_state_props(count: int) -> void:
	_sent_state_props_accum += count

func push_sent_state_broadcast(state: Dictionary) -> void:
	_sent_state_props_accum += state.size() * (multiplayer.get_peers().size() - 1)

## Get the number of corrections received during the last tick loop.
## [br][br]
## A correction is an authoritative state received for a node this peer
## simulates, that differs from the state recorded for the same tick. See
## [signal _NetworkRollback.on_correction].
func get_corrections() -> int:
	return _corrections

## Get the number of corrections received since monitoring started.
func get_corrections_total() -> int:
	return _corrections_total

func push_corrections(count: int) -> void:
	_corrections_accum += count
	_corrections_total += count

## Get the number of nodes simulated for the first time for their tick during
## the last rollback loop.
func get_rollback_nodes_fresh() -> int:
	return _rollback_nodes_fresh

func push_rollback_nodes_fresh(count: int) -> void:
	_rollback_nodes_fresh_accum += count

## Get the number of nodes simulated during the last rollback loop with input
## for their tick received or recorded since the loop before.
## [br][br]
## The rest of [method get_rollback_nodes_simulated] reran a tick whose input
## was already known.
func get_rollback_nodes_with_new_input() -> int:
	return _rollback_nodes_new_input

func push_rollback_nodes_with_new_input(count: int) -> void:
	_rollback_nodes_new_input_accum += count

## Get the peers that sent input during the last window of input lateness.
func get_input_lateness_peers() -> Array:
	return _input_lateness.keys()

## Get how late [param peer]'s accepted inputs were on average, in ticks
## behind the current tick on arrival, over the last second.
## [br][br]
## Each tick of input accepted counts once, including ticks recovered from
## input redundancy. Negative values mean input arrived early. Returns 0 if no
## input was accepted.
func get_input_lateness_mean(peer: int) -> float:
	var entry := _input_lateness.get(peer, [0, 0, 0]) as Array
	return entry[0] / maxf(1., entry[1])

## Get the latest of [param peer]'s inputs accepted in the last second, in
## ticks behind the current tick on arrival. Returns 0 if no input was accepted.
func get_input_lateness_max(peer: int) -> int:
	return (_input_lateness.get(peer, [0, 0, 0]) as Array)[2]

## Get the mean input lateness over all peers in the last second, in ticks.
func get_input_lateness_mean_all() -> float:
	var sum := 0
	var count := 0
	for entry in _input_lateness.values():
		sum += entry[0]
		count += entry[1]
	return sum / maxf(1., count)

## Get the maximum input lateness over all peers in the last second, in ticks.
func get_input_lateness_max_all() -> int:
	var result := 0
	for entry in _input_lateness.values():
		result = maxi(result, entry[2])
	return result

func push_input_lateness(peer: int, ticks: int) -> void:
	if not _input_lateness_accum.has(peer):
		_input_lateness_accum[peer] = [ticks, 1, ticks]
		return
	var entry := _input_lateness_accum[peer] as Array
	entry[0] += ticks
	entry[1] += 1
	entry[2] = maxi(entry[2], ticks)

## Get the bytes of rollback state handed to [_NetworkCommandServer] during the
## last tick loop, full and diff states together.
func get_sent_state_bytes() -> int:
	return _sent_bytes.get(&"state", 0)

## Get the bytes of rollback input handed to [_NetworkCommandServer] during the
## last tick loop.
func get_sent_input_bytes() -> int:
	return _sent_bytes.get(&"input", 0)

## Get the bytes of [StateSynchronizer] state handed to
## [_NetworkCommandServer] during the last tick loop.
func get_sent_sync_state_bytes() -> int:
	return _sent_bytes.get(&"sync", 0)

func _ready() -> void:
	_enabled = is_enabled()
	if not _enabled:
		_logger.debug("Network performance disabled")
		return

	_logger.debug("Network performance enabled, registering performance monitors")
	Performance.add_custom_monitor(NETWORK_LOOP_DURATION_MONITOR, get_network_loop_duration_ms)
	Performance.add_custom_monitor(ROLLBACK_LOOP_DURATION_MONITOR, get_rollback_loop_duration_ms)
	Performance.add_custom_monitor(NETWORK_TICKS_MONITOR, get_network_ticks)
	Performance.add_custom_monitor(ROLLBACK_TICKS_MONITOR, get_rollback_ticks)
	Performance.add_custom_monitor(ROLLBACK_TICK_DURATION_MONITOR, get_rollback_tick_duration_ms)
	Performance.add_custom_monitor(ROLLBACK_NODES_SIMULATED_MONITOR, get_rollback_nodes_simulated)
	Performance.add_custom_monitor(ROLLBACK_NODES_SIMULATED_PER_TICK_MONITOR, get_rollback_nodes_simulated_per_tick)

	Performance.add_custom_monitor(FULL_STATE_PROPERTIES_COUNT, get_full_state_props_count)
	Performance.add_custom_monitor(SENT_STATE_PROPERTIES_COUNT, get_sent_state_props_count)
	Performance.add_custom_monitor(SENT_STATE_PROPERTIES_RATIO, get_sent_state_props_ratio)

	Performance.add_custom_monitor(CORRECTIONS_MONITOR, get_corrections)
	Performance.add_custom_monitor(ROLLBACK_NODES_FRESH_MONITOR, get_rollback_nodes_fresh)
	Performance.add_custom_monitor(ROLLBACK_NODES_NEW_INPUT_MONITOR, get_rollback_nodes_with_new_input)
	Performance.add_custom_monitor(INPUT_LATENESS_MEAN_MONITOR, get_input_lateness_mean_all)
	Performance.add_custom_monitor(INPUT_LATENESS_MAX_MONITOR, get_input_lateness_max_all)
	Performance.add_custom_monitor(SENT_STATE_BYTES_MONITOR, get_sent_state_bytes)
	Performance.add_custom_monitor(SENT_INPUT_BYTES_MONITOR, get_sent_input_bytes)
	Performance.add_custom_monitor(SENT_SYNC_STATE_BYTES_MONITOR, get_sent_sync_state_bytes)

	NetworkTime.before_tick_loop.connect(_before_tick_loop)
	NetworkTime.on_tick.connect(_on_network_tick)
	NetworkTime.after_tick_loop.connect(_after_tick_loop)

	NetworkRollback.before_loop.connect(_before_rollback_loop)
	NetworkRollback.on_process_tick.connect(_on_rollback_tick)
	NetworkRollback.after_loop.connect(_after_rollback_loop)

func _before_tick_loop() -> void:
	_network_loop_start = _time()
	_network_ticks_accum = 0

func _on_network_tick(_dt, _t) -> void:
	_network_ticks_accum += 1

func _after_tick_loop() -> void:
	_network_loop_duration = _time() - _network_loop_start
	_network_ticks = _network_ticks_accum

	_full_state_props = _full_state_props_accum
	_full_state_props_accum = 0

	_sent_state_props = _sent_state_props_accum
	_sent_state_props_accum = 0

	_corrections = _corrections_accum
	_corrections_accum = 0

	if NetworkTime.tick >= _input_lateness_window_end:
		_input_lateness = _input_lateness_accum
		_input_lateness_accum = {}
		_input_lateness_window_end = NetworkTime.tick + NetworkTime.tickrate

	var sync_server := NetworkSynchronizationServer
	_update_sent_bytes(&"state", [sync_server._cmd_full_state, sync_server._cmd_diff_state])
	_update_sent_bytes(&"input", [sync_server._cmd_input])
	_update_sent_bytes(&"sync", [sync_server._cmd_full_sync, sync_server._cmd_diff_sync])

func _before_rollback_loop() -> void:
	_rollback_loop_start = _time()
	_rollback_ticks_accum = 0
	_rollback_nodes_simulated_accum = 0
	_rollback_nodes_fresh_accum = 0
	_rollback_nodes_new_input_accum = 0

func _on_rollback_tick(_t: int) -> void:
	_rollback_ticks_accum += 1

func _after_rollback_loop() -> void:
	_rollback_loop_duration = _time() - _rollback_loop_start
	_rollback_ticks = _rollback_ticks_accum
	_rollback_nodes_simulated = _rollback_nodes_simulated_accum
	_rollback_nodes_fresh = _rollback_nodes_fresh_accum
	_rollback_nodes_new_input = _rollback_nodes_new_input_accum

func _update_sent_bytes(kind: StringName, commands: Array) -> void:
	var total := 0
	for command in commands:
		if command:
			total += (command as NetworkCommandServer.Command).get_sent_bytes()
	_sent_bytes[kind] = total - _sent_bytes_totals.get(kind, total)
	_sent_bytes_totals[kind] = total

func _time() -> float:
	return Time.get_unix_time_from_system()
