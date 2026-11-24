extends Node
class_name _NetworkSynchronizationServer

# @public class

## Synchronizes properties over the network
##
## Handles synchronization of rollback and state properties (
## [RollbackSynchronizer] and [StateSynchronizer] ), while respecting visibility
## filters and schemas for serialization.
## [br][br]
## Packets are sent per tick, instead of per object. So for every simulated
## rollback tick, a packet is sent with states, and for every recorded input,
## a packet is sent with the inputs.
## [br][br]
## Optionally, diff states can be used, sending only the property values that
## have changed, saving on bandwidth.
## [br][br]
## With [code]netfox/rollback/send_newest_state_only[/code], rollback state is
## instead sent once per rollback loop: each peer gets, for each node it sees,
## the node's newest authoritative state if it differs from the one it was last
## sent, in one packet with a tick per node.

# Dependencies
var _command_server: _NetworkCommandServer
var _history_server: _NetworkHistoryServer
var _identity_server: _NetworkIdentityServer
var _simulation_server: _RollbackSimulationServer

# Configuration
var _rb_input_properties := _PropertyPool.new()
var _rb_state_properties := _PropertyPool.new()
var _rb_owned_input_properties := _PropertyPool.new()
var _rb_owned_state_properties := _PropertyPool.new()
var _rb_owner_only_state_properties := _PropertyPool.new()
var _sync_state_properties := _PropertyPool.new()
var _sync_owned_state_properties := _PropertyPool.new()

var _visibility_filters := {} # Node to PeerVisibilityFilter

var _starvation_ticks := {} # input subject to the ticks of silence it starves after
var _newest_input := {} # input subject to the newest tick of input received
var _gap_checked := {} # input subject to the last tick checked for a gap
var _fills := {} # input subject to (filled tick to true if starved, false if a gap)
var _starved_from := {} # input subject to the first tick of its current silence
var _starve_filled := {} # input subject to the last tick filled in its current silence

var _rb_enable_input_broadcast := ProjectSettings.get_setting("netfox/rollback/enable_input_broadcast", false) as bool
var _rb_enable_diffs := NetworkRollback.enable_diff_states
var _rb_full_interval := ProjectSettings.get_setting("netfox/rollback/full_state_interval", 24) as int
var _rb_full_scheduler := _IntervalScheduler.new(_rb_full_interval)

var _input_redundancy := NetworkRollback.input_redundancy
var _input_max_late := ProjectSettings.get_setting("netfox/rollback/input_max_late_ticks", -1) as int
var _input_max_early := ProjectSettings.get_setting("netfox/rollback/input_max_early_ticks", 4) as int

var _rb_sent_state_history := {} # peer to _HistoryBuffer of _Snapshot
var _rb_latest_received_state := {} # Node to tick

var _rb_send_newest_only := ProjectSettings.get_setting("netfox/rollback/send_newest_state_only", false) as bool
var _rb_send_intermediate := ProjectSettings.get_setting("netfox/rollback/send_intermediate_states_to_others", false) as bool
var _rb_newest_sent := {} # peer to (subject to _SentState)
var _rb_newest_loop_to := -1 # The last tick the previous loop recorded

var _last_sync_state_sent := _Snapshot.new(0)
var _sync_sent_subjects := {} # peer to _Set of subjects sent since visible
var _sync_enable_diffs := ProjectSettings.get_setting("netfox/state_synchronizer/enable_diff_states", true) as bool
var _sync_full_interval := ProjectSettings.get_setting("netfox/state_synchronizer/full_state_interval", 24) as int
var _sync_full_scheduler := _IntervalScheduler.new(_sync_full_interval)

# Very conservative packet size limit, source:
# https://stackoverflow.com/a/35697810
var _max_packet_size := ProjectSettings.get_setting("netfox/general/max_sync_packet_size", 508) as int

var _schemas := _NetworkSchema.new()

var _dense_serializer: _DenseSnapshotSerializer
var _sparse_serializer: _SparseSnapshotSerializer
var _redundant_serializer: _RedundantSnapshotSerializer
var _ticked_serializer: _TickedSnapshotSerializer

var _cmd_full_state: NetworkCommandServer.Command
var _cmd_diff_state: NetworkCommandServer.Command
var _cmd_input: NetworkCommandServer.Command
var _cmd_newest_state: NetworkCommandServer.Command

var _cmd_full_sync: NetworkCommandServer.Command
var _cmd_diff_sync: NetworkCommandServer.Command

static var _logger := NetfoxLogger._for_netfox("NetworkSynchronizationServer")

signal _on_input(snapshot: _Snapshot)
signal _on_state(snapshot: _Snapshot)

## Emitted when input for [param tick] from [param peer] is refused, as it falls
## outside of the ticks input is accepted for.
## [br][br]
## Input is accepted for ticks from [code]netfox/rollback/input_max_late_ticks[/code]
## before the current tick, up to [code]netfox/rollback/input_max_early_ticks[/code]
## after it, plus the input delay. Redundant copies of input already received are
## dropped without a refusal.
signal on_input_refused(peer: int, tick: int)

## Register a [param property] of [param node] to be synchronized
## as rollback state
## [br][br]
## With [param owner_only], the property is sent only to the peers owning an
## input of [param node]. Other peers keep their own records of it.
func register_rollback_state(node: Node, property: NodePath, owner_only: bool = false) -> void:
	_rb_state_properties.add(node, property)
	if node.is_multiplayer_authority():
		_rb_owned_state_properties.add(node, property)
	if owner_only:
		_rb_owner_only_state_properties.add(node, property)

## Deregister a [param property] of [param node] from being
## synchronized as rollback state
func deregister_rollback_state(node: Node, property: NodePath) -> void:
	_rb_state_properties.erase(node, property)
	_rb_owned_state_properties.erase(node, property)
	_rb_owner_only_state_properties.erase(node, property)

## Register a [param property] of [param node] to be synchronized
## as rollback input
func register_rollback_input(node: Node, property: NodePath) -> void:
	_rb_input_properties.add(node, property)
	if node.is_multiplayer_authority():
		_rb_owned_input_properties.add(node, property)

## Deregister a [param property] of [param node] from being
## synchronized as rollback input
func deregister_rollback_input(node: Node, property: NodePath) -> void:
	_rb_input_properties.erase(node, property)
	_rb_owned_input_properties.erase(node, property)

## Register a [param property] of [param node] to be synchronized
## as synchronized state
func register_sync_state(node: Node, property: NodePath) -> void:
	_sync_state_properties.add(node, property)
	if node.is_multiplayer_authority():
		_sync_owned_state_properties.add(node, property)

## Deregister a [param property] of [param node] from being
## synchronized as synchronized state
func deregister_sync_state(node: Node, property: NodePath) -> void:
	_sync_state_properties.erase(node, property)
	_sync_owned_state_properties.erase(node, property)

## Register a [param serializer] to use when transmitting
## [param property param] of [param node] over the network
func register_schema(node: Node, property: NodePath, serializer: NetworkSchemaSerializer) -> void:
	_schemas.add(node, property, serializer)

## Deregister any serializers used for [param property] on
## [param node] when transmitting over the network
func deregister_schema(node: Node, property: NodePath) -> void:
	_schemas.erase(node, property)

## Deregister all serializers registered for any properties of
## [param node]
func deregister_schema_for(node: Node) -> void:
	_schemas.erase_subject(node)

## Register a visibility [param filter] for use with [param node]
func register_visibility_filter(node: Node, filter: PeerVisibilityFilter) -> void:
	_visibility_filters[node] = filter

## Deregister the visibility filter used for [param node]
func deregister_visibility_filter(node: Node) -> void:
	_visibility_filters.erase(node)

## Set the input starvation threshold of [param input], in ticks; 0 disables it
## [br][br]
## With starvation, missing input of [param input]'s owner is filled as if
## received, so the nodes it controls are simulated and their state is sent:
## [br]- A tick whose input can no longer arrive, as input [code]input_redundancy[/code]
## ticks newer has, gets a copy of the input before it.
## [br]- Once the newest input is more than [param ticks] old, the owner is
## silent: every tick after it is filled up to the current one, then each new
## tick as it is simulated. Before recording each, [code]_rollback_starve(tick)[/code]
## is called on [param input] if it has one, so the game can adjust the copied
## input, e.g. release the triggers.
## [br]- The first input received again ends the silence at its tick: the
## fills from it on are withdrawn for the real input, the earlier ones stay and
## real input for them, or for ticks before the silence, is refused.
## [br][br]
## Nothing is filled before the owner's first input, where this peer does not
## own the controlled nodes, for a dead or despawned node, or while the owner is
## not connected.
func set_input_starvation_for(input: Node, ticks: int) -> void:
	if ticks > 0:
		_starvation_ticks[input] = ticks
		return
	for data in [_starvation_ticks, _newest_input, _gap_checked, _fills, _starved_from, _starve_filled]:
		(data as Dictionary).erase(input)

## Deregister any and all settings associated with [param node]
func deregister(node: Node) -> void:
	_rb_state_properties.erase_subject(node)
	_rb_input_properties.erase_subject(node)
	_rb_owned_state_properties.erase_subject(node)
	_rb_owned_input_properties.erase_subject(node)
	_rb_owner_only_state_properties.erase_subject(node)
	_sync_state_properties.erase_subject(node)
	_sync_owned_state_properties.erase_subject(node)
	_visibility_filters.erase(node)
	_schemas.erase_subject(node)
	_rb_latest_received_state.erase(node)
	set_input_starvation_for(node, 0)
	for sent_subjects in _sync_sent_subjects.values():
		(sent_subjects as _Set).erase(node)
	for sent_states in _rb_newest_sent.values():
		(sent_states as Dictionary).erase(node)

	# NOTE: _rb_sent_state_history may contain snapshots with invalid subjects
	# NOTE: Iterating all sent snapshots for `node` may be slow and useless

## Erase all data kept about [param peer].
## [br][br]
## Called by default when a peer leaves
func erase_peer(peer: int) -> void:
	_rb_sent_state_history.erase(peer)
	_rb_newest_sent.erase(peer)
	_sync_sent_subjects.erase(peer)

## Forget what was sent to other peers, while keeping the registered properties
## [br][br]
## Sent states are the reference for diff states, and are indexed by tick, so
## they must not carry over to the next session. Called by
## [method _NetworkTime.stop].
func reset() -> void:
	_rb_sent_state_history.clear()
	_rb_latest_received_state.clear()
	_rb_newest_sent.clear()
	_rb_newest_loop_to = -1
	for data in [_newest_input, _gap_checked, _fills, _starved_from, _starve_filled]:
		(data as Dictionary).clear()
	_last_sync_state_sent = _Snapshot.new(0)
	_sync_sent_subjects.clear()

## Ingest rollback [param input] for [param subject] at [param tick], as if it
## was received from the subject's authority
## [br][br]
## The [param input] maps the subject's property paths to their values, like
## [method _NetworkHistoryServer.get_rollback_input_at] returns them. It is
## merged into the history, triggering a resimulation if it's new.
## [br][br]
## Useful to carry input between nodes in the same process, e.g. in tests.
func inject_rollback_input(subject: Node, tick: int, input: Dictionary) -> void:
	_ingest_input(subject.get_multiplayer_authority(), _make_subject_snapshot(subject, tick, input))

## Ingest rollback [param state] for [param subject] at [param tick], as if it
## was received from the subject's authority
## [br][br]
## The [param state] maps the subject's property paths to their values, like
## [method _NetworkHistoryServer.get_rollback_state_at] returns them. It is
## merged into the history, triggering a resimulation if it changes anything.
## [br][br]
## Useful to carry state between nodes in the same process, e.g. in tests.
func inject_rollback_state(subject: Node, tick: int, state: Dictionary) -> void:
	_ingest_state(subject.get_multiplayer_authority(), _make_subject_snapshot(subject, tick, state))

## Return the tick of the newest authoritative rollback state received for
## [param subject], or -1 if none was received.
## [br][br]
## Updated by every state received, whether or not it changed the recorded
## history. Useful for e.g. displaying remote nodes a few ticks behind their
## newest state, as states may arrive in bursts.
func get_latest_received_state_tick_for(subject: Node) -> int:
	return _rb_latest_received_state.get(subject, -1)

func _get_peer_rb_sent_history(peer: int) -> _HistoryBuffer:
	if not _rb_sent_state_history.has(peer):
		_rb_sent_state_history[peer] = _HistoryBuffer.new(NetworkRollback.history_limit)
	return _rb_sent_state_history[peer]

func _get_last_sent_rollback_state(peer: int, tick: int) -> _Snapshot:
	var history: _HistoryBuffer = _rb_sent_state_history.get(peer, null)
	if history == null or not history.has_latest_at(tick):
		return null
	return history.get_latest_at(tick)

func _remember_sent_rollback_state(peer: int, snapshot: _Snapshot) -> void:
	var reference := _get_last_sent_rollback_state(peer, snapshot.tick)
	_get_peer_rb_sent_history(peer).set_at(snapshot.tick, _merge_sent_rollback_state(reference, snapshot))

# Return what a peer knows after being sent `snapshot` on top of `reference`
# The result is never modified, so peers sent the same may share it
func _merge_sent_rollback_state(reference: _Snapshot, snapshot: _Snapshot) -> _Snapshot:
	var remembered := reference.duplicate() if reference else _Snapshot.new(snapshot.tick)

	# `snapshot` might be a diff state, hence the merging
	for subject in snapshot.get_subjects():
		for property in snapshot.get_subject_properties(subject):
			remembered.set_property(subject, property, snapshot.get_property(subject, property))
		remembered.set_auth(subject, snapshot.is_auth(subject))
	remembered.tick = snapshot.tick
	return remembered

# Prepare snapshot to be sent to `peer`
# Only contains visible subjects' auth properties, and owner-only properties of
# the subjects whose input `peer` owns
func _make_peer_snapshot(snapshot: _Snapshot, peer: int, properties: _PropertyPool) -> _Snapshot:
	var subjects := _get_visible_auth_subjects(snapshot, peer, properties)
	return _make_subjects_snapshot(snapshot, subjects, properties, _get_input_owned_subjects(subjects, peer))

func _get_visible_auth_subjects(snapshot: _Snapshot, peer: int, properties: _PropertyPool) -> Array:
	var result := []
	for subject in properties.get_subjects_raw():
		if _is_node_visible_to(peer, subject) and snapshot.is_auth(subject):
			result.append(subject)
	return result

# Owner-only properties are included only for `owned_subjects`
func _make_subjects_snapshot(snapshot: _Snapshot, subjects: Array, properties: _PropertyPool, owned_subjects: Array = []) -> _Snapshot:
	var result := _Snapshot.new(snapshot.tick)
	for subject in subjects:
		var has_property := false
		var is_owned := owned_subjects.has(subject)
		for property in properties.get_properties_of_raw(subject):
			if not snapshot.has_property(subject, property):
				continue
			if not is_owned and _rb_owner_only_state_properties.has(subject, property):
				continue
			result.set_property(subject, property, snapshot.get_property(subject, property))
			has_property = true

		if has_property:
			result.set_auth(subject, true)
	return result

# Peers whose last sent states hold the same are sent the same, whether they
# share the record or not
func _is_same_sent_state(snapshot: _Snapshot, other: _Snapshot) -> bool:
	if snapshot == other:
		return true
	if snapshot == null or other == null:
		return false
	return snapshot._data == other._data and snapshot._auth_subjects._data == other._auth_subjects._data

# Return the subjects with owner-only properties whose input [param peer] owns
func _get_input_owned_subjects(subjects: Array, peer: int) -> Array:
	var result := []
	if _rb_owner_only_state_properties.is_empty():
		return result
	for subject in subjects:
		if _rb_owner_only_state_properties.has_subject(subject) and _is_input_owner(subject, peer):
			result.append(subject)
	return result

func _is_input_owner(subject: Object, peer: int) -> bool:
	for input in _simulation_server._get_inputs_of(subject):
		if input.get_multiplayer_authority() == peer:
			return true
	return false

# Return a filter for the properties of a full state sent to or received by
# [param peer]: owner-only properties only for the subjects it owns input of
func _get_state_property_filter(peer: int) -> Callable:
	if _rb_owner_only_state_properties.is_empty():
		return _BaseSnapshotSerializer._default_property_filter
	return func(subject: Object, property: NodePath) -> bool:
		return not _rb_owner_only_state_properties.has(subject, property) or _is_input_owner(subject, peer)

func _has_owned_auth_subject(snapshot: _Snapshot) -> bool:
	for subject in snapshot.get_auth_subjects():
		if _rb_owned_state_properties.has_subject(subject):
			return true
	return false

func _is_node_visible_to(peer: int, node: Node) -> bool:
	var filter := _visibility_filters.get(node) as PeerVisibilityFilter
	if not filter:
		return true
	else:
		return filter.get_visible_peers().has(peer)

func _synchronize_input(tick: int) -> void:
	# We don't own inputs, nothing to synchronize
	if _rb_owned_input_properties.is_empty():
		return

	var snapshots := [] as Array[_Snapshot]
	var notified_peers := _Set.new()

	if not _rb_enable_input_broadcast:
		# If input broadcast is off, find which peers need to know our inputs
		# That is all peers who own state controlled by our input

		# Grab owned input objects
		for input_subject in _rb_owned_input_properties.get_subjects():
			# Grab state objects controlled by input
			var controlled_nodes := RollbackSimulationServer._get_controlled_by(input_subject)

			# Notify peers owning nodes about the input
			for node in controlled_nodes:
				notified_peers.add(node.get_multiplayer_authority())
	else:
		# If input broadcast is on, send inputs to everyone
		for peer in multiplayer.get_peers():
			notified_peers.add(peer)

	# Make sure to not send input to ourselves
	notified_peers.erase(multiplayer.get_unique_id())

	# Prepare snapshot package
	for offset in _input_redundancy:
		# Grab snapshot from NetworkHistoryServer
		var snapshot := NetworkHistoryServer._get_rollback_input_snapshot(tick - offset)
		if not snapshot:
			break

		_logger.trace("Submitting input: %s", [snapshot])
		snapshots.append(snapshot)

	_logger.trace("Submitting input to peers: %s", [notified_peers])
	for peer in notified_peers:
		var data := _redundant_serializer.write_for(peer, snapshots, _rb_owned_input_properties)
		_cmd_input.send(data, peer)

func _synchronize_state(tick: int) -> void:
	# We don't own state, nothing to synchronize; or it's sent after the loop
	if _rb_owned_state_properties.is_empty() or _rb_send_newest_only:
		return

	# Grab snapshot from NetworkHistoryServer
	var snapshot := _history_server._get_rollback_state_snapshot(tick)
	if not snapshot:
		# No data for tick
		return

	if snapshot.is_empty():
		# Nothing to send
		return

	# Figure out whether to send full- or diff state
	var is_full := _rb_full_scheduler.is_now()
	if not _rb_enable_diffs:
		is_full = true

	# No peer gets state of a tick where we have no auth state, e.g. while
	# waiting for input
	if not _has_owned_auth_subject(snapshot):
		return

	# Peers that see the same subjects, own input of the same ones and were sent
	# the same states before get the same state, so it is prepared once for each
	# such group
	var peer_snapshots := {} # [visible subjects, input owned subjects] to peer snapshot
	var prepared := {} # [peer snapshot, is full] to [[reference, sent, remembered]]
	# Each subject's encoded data, shared by all peers sent the same of it
	var full_frames := {}
	var diff_frames := {}
	for peer in _get_peers():
		var visible_subjects := _get_visible_auth_subjects(snapshot, peer, _rb_owned_state_properties)
		if visible_subjects.is_empty():
			continue

		var owned_subjects := _get_input_owned_subjects(visible_subjects, peer)
		var subjects_key := [visible_subjects, owned_subjects]
		var peer_snapshot := peer_snapshots.get(subjects_key) as _Snapshot
		if peer_snapshot == null:
			peer_snapshot = _make_subjects_snapshot(snapshot, visible_subjects, _rb_owned_state_properties, owned_subjects)
			peer_snapshots[subjects_key] = peer_snapshot
		if peer_snapshot.is_empty():
			continue

		var reference_snapshot := _get_last_sent_rollback_state(peer, tick)
		var peer_is_full := is_full or reference_snapshot == null

		var key := [peer_snapshot, peer_is_full]
		var states := prepared.get(key, []) as Array
		var state := []
		for candidate in states:
			if _is_same_sent_state(candidate[0], reference_snapshot):
				state = candidate
				break

		if state.is_empty():
			var sent := peer_snapshot if peer_is_full else _Snapshot.make_patch(reference_snapshot, peer_snapshot)
			var remembered: _Snapshot = null
			if not sent.is_empty():
				remembered = _merge_sent_rollback_state(reference_snapshot, sent)
			state = [reference_snapshot, sent, remembered]
			states.append(state)
			prepared[key] = states

		var sent := state[1] as _Snapshot
		if sent.is_empty():
			# Nothing changed, don't send anything
			continue

		if peer_is_full:
			var packets := _dense_serializer.write_for(peer, sent, _rb_owned_state_properties, _BaseSnapshotSerializer._default_filter, full_frames, _get_state_property_filter(peer))
			for packet in packets:
				_cmd_full_state.send(packet, peer)
		else:
			var packets := _sparse_serializer.write_for(peer, sent, _rb_owned_state_properties, _BaseSnapshotSerializer._default_filter, diff_frames)
			for packet in packets:
				_cmd_diff_state.send(packet, peer)

		_get_peer_rb_sent_history(peer).set_at(tick, state[2])
		NetworkPerformance.push_full_state_props(peer_snapshot.size())
		NetworkPerformance.push_sent_state_props(sent.size())

# Send each peer, for each subject it sees, the subject's newest authoritative
# state if it differs from the one it was last sent of it - in full for a
# subject it was sent nothing of since it could see it, or on a full state
# Called once after the rollback loop that recorded up to [param to]
func _synchronize_newest_state(to: int) -> void:
	if not _rb_send_newest_only or _rb_owned_state_properties.is_empty():
		return

	# The full state interval counts ticks, as when sending every tick
	var is_full := not _rb_enable_diffs
	var new_ticks := to - _rb_newest_loop_to if _rb_newest_loop_to >= 0 else 1
	for i in clampi(new_ticks, 1, maxi(_rb_full_scheduler.interval, 1)):
		if _rb_full_scheduler.is_now():
			is_full = true
	_rb_newest_loop_to = to

	var history := _history_server._rb_state_history
	var history_start := NetworkRollback.history_start
	var newest := {} # subject to its newest auth tick
	for subject in _rb_owned_state_properties.get_subjects_raw():
		var tick := history.get_latest_auth_tick(to, subject, history_start)
		if tick >= 0:
			newest[subject] = tick
	if newest.is_empty():
		return

	# Peers sent the same of a subject share what they were sent, so its state
	# is compared and encoded once for all of them
	var values_of := {} # [subject, is input owner] to the values a peer may get
	var prepared := {} # [subject, is input owner, sent before] to [values to send, sent after]
	var frames := {}
	for peer in _get_peers():
		var sent_states := _get_peer_newest_sent(peer)
		var entries := []
		var full_props := 0
		var sent_props := 0
		for subject in _rb_owned_state_properties.get_subjects_raw():
			if not _is_node_visible_to(peer, subject):
				sent_states.erase(subject)
				continue
			if not newest.has(subject):
				continue

			var tick := newest[subject] as int
			var is_owner := false
			var is_chained := false
			var reference := sent_states.get(subject) as _SentState
			if _rb_send_intermediate or _rb_owner_only_state_properties.has_subject(subject):
				var owns_input := _is_input_owner(subject, peer)
				is_owner = owns_input and _rb_owner_only_state_properties.has_subject(subject)
				is_chained = _rb_send_intermediate and not owns_input and not is_full and reference != null and reference.tick < tick
			var values_key := [subject, is_owner]
			var key := [subject, is_owner, reference, is_chained, is_full]
			var result := prepared.get(key, []) as Array
			if result.is_empty():
				if not values_of.has(values_key):
					values_of[values_key] = _get_newest_values(subject, tick, is_owner)
				result = _prepare_newest(subject, tick, values_of[values_key], is_owner, reference, is_chained, is_full)
				prepared[key] = result

			var sends := result[0] as Array
			if sends.is_empty():
				continue
			for send in sends:
				entries.append([subject, send[0], send[1]])
				sent_props += (send[1] as Dictionary).size()
			sent_states[subject] = result[1]
			full_props += (values_of[values_key] as Dictionary).size()

		if entries.is_empty():
			continue
		for packet in _ticked_serializer.write_for(peer, to, entries, _rb_owned_state_properties, frames):
			_cmd_newest_state.send(packet, peer)
		NetworkPerformance.push_full_state_props(full_props)
		NetworkPerformance.push_sent_state_props(sent_props)

# Return [[tick, values to send], ...] and what the peer was sent after them:
# the newest state, as a diff against [param reference], and with
# [param is_chained] first each authoritative state between the two. With
# [param is_full], the newest state in full, unless it is the one sent before:
# a node waiting for input, as its owner fell silent, is sent nothing
func _prepare_newest(subject: Object, tick: int, values: Dictionary, is_owner: bool, reference: _SentState, is_chained: bool, is_full: bool) -> Array:
	var sends := []
	var last := reference
	if is_chained:
		var history := _history_server._rb_state_history
		var between := []
		var at := history.get_latest_auth_tick(tick - 1, subject, reference.tick + 1)
		while at >= 0:
			between.push_front(at)
			at = history.get_latest_auth_tick(at - 1, subject, reference.tick + 1)
		for between_tick in between:
			var between_values := _get_newest_values(subject, between_tick, is_owner)
			var diff := _diff_values(last.values, between_values)
			if not diff.is_empty():
				sends.append([between_tick, diff])
				last = _SentState.new(between_tick, between_values)

	var diff := values if last == null else _diff_values(last.values, values)
	if is_full and (last == null or tick > last.tick or not diff.is_empty()):
		diff = values
	if not diff.is_empty():
		sends.append([tick, diff])
		last = _SentState.new(tick, values)
	return [sends, last]

# The values of [param subject]'s state recorded at [param tick] that a peer
# gets: owner-only properties only if [param is_owner]
func _get_newest_values(subject: Object, tick: int, is_owner: bool) -> Dictionary:
	var record := _history_server._rb_state_history.get_snapshot(tick, subject)
	var result := {}
	for property in _rb_owned_state_properties.get_properties_of_raw(subject):
		if not is_owner and _rb_owner_only_state_properties.has(subject, property):
			continue
		assert(record.has_value(property), "Trying to send missing property %s on subject %s!" % [property, subject])
		result[property] = record.get_value(property)
	return result

# The values of [param values] that [param reference] lacks or holds otherwise
func _diff_values(reference: Dictionary, values: Dictionary) -> Dictionary:
	var result := {}
	for property in values:
		if not reference.has(property) or reference[property] != values[property]:
			result[property] = values[property]
	return result

func _get_peer_newest_sent(peer: int) -> Dictionary:
	if not _rb_newest_sent.has(peer):
		_rb_newest_sent[peer] = {}
	return _rb_newest_sent[peer]

func _synchronize_sync_state(tick: int) -> void:
	# We don't own sync state, nothing to synchronize
	if _sync_owned_state_properties.is_empty():
		return

	# Grab snapshot from NetworkHistoryServer
	var snapshot := NetworkHistoryServer._get_synchronizer_state_snapshot(tick)
	if not snapshot:
		return

	# Figure out whether to send full- or diff state
	var is_full := _sync_full_scheduler.is_now()
	if not _sync_enable_diffs:
		is_full = true

	var diff: _Snapshot = null
	if not is_full:
		diff = _Snapshot.make_patch(_last_sync_state_sent, snapshot)

	# Each subject's encoded data, shared by all peers sent the same of it
	var shared_frames := {}

	for peer in _get_peers():
		# A diff is relative to the previous tick's state, which a subject the peer
		# could not see was not sent with - send such subjects in full first
		var sent_subjects := _get_peer_sync_subjects(peer)
		var peer_diff := diff
		for subject in _sync_owned_state_properties.get_subjects_raw():
			if not _is_node_visible_to(peer, subject):
				sent_subjects.erase(subject)
				continue
			if sent_subjects.has(subject) or not snapshot.is_auth(subject):
				continue

			sent_subjects.add(subject)
			if not is_full:
				if peer_diff == diff:
					peer_diff = diff.duplicate()
				snapshot.copy_subject_to(subject, peer_diff)
				peer_diff.set_auth(subject, true)

		var filter := func(subject): return sent_subjects.has(subject)

		if is_full:
			var packets := _dense_serializer.write_for(peer, snapshot, _sync_owned_state_properties, filter, shared_frames)
			for packet in packets:
				_cmd_full_sync.send(packet, peer)

			NetworkPerformance.push_full_state_props(snapshot.size())
			NetworkPerformance.push_sent_state_props(snapshot.size())
		else:
			# Nothing is sent if no visible subject changed
			var packets := _sparse_serializer.write_for(peer, peer_diff, _sync_owned_state_properties, filter, shared_frames)
			for packet in packets:
				_cmd_diff_sync.send(packet, peer)

			NetworkPerformance.push_full_state_props(snapshot.size())
			NetworkPerformance.push_sent_state_props(peer_diff.size())

	# Remember last sent state for diffing
	# NOTE: This is a shared instance, theoretically shouldn't screw things up
	_last_sync_state_sent = snapshot

func _get_peers() -> PackedInt32Array:
	return multiplayer.get_peers()

# Asks the node's own multiplayer, which may differ from ours
func _is_peer_connected(node: Node, peer: int) -> bool:
	return node.multiplayer.get_peers().has(peer)

func _get_peer_sync_subjects(peer: int) -> _Set:
	if not _sync_sent_subjects.has(peer):
		_sync_sent_subjects[peer] = _Set.new()
	return _sync_sent_subjects[peer]

func _init(
		p_command_server: _NetworkCommandServer = null,
		p_history_server: _NetworkHistoryServer = null,
		p_identity_server: _NetworkIdentityServer = null,
		p_simulation_server: _RollbackSimulationServer = null
	) -> void:
	_command_server = p_command_server
	_history_server = p_history_server
	_identity_server = p_identity_server
	_simulation_server = p_simulation_server

func _ready() -> void:
	# Ensure dependencies
	if not _command_server: _command_server = NetworkCommandServer
	if not _history_server: _history_server = NetworkHistoryServer
	if not _identity_server: _identity_server = NetworkIdentityServer
	if not _simulation_server: _simulation_server = RollbackSimulationServer

	# Setup serializers
	_dense_serializer = _DenseSnapshotSerializer.new(_schemas, _identity_server)
	_sparse_serializer = _SparseSnapshotSerializer.new(_schemas, _identity_server)
	_redundant_serializer = _RedundantSnapshotSerializer.new(_schemas, _identity_server)
	_ticked_serializer = _TickedSnapshotSerializer.new(_schemas, _identity_server)

	_dense_serializer.max_packet_size = _max_packet_size
	_sparse_serializer.max_packet_size = _max_packet_size
	_redundant_serializer.max_packet_size = _max_packet_size
	_ticked_serializer.max_packet_size = _max_packet_size

	# Setup commands
	_cmd_full_state = _command_server.register_command(_handle_full_state, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	_cmd_diff_state = _command_server.register_command(_handle_diff_state, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	_cmd_input = _command_server.register_command(_handle_input, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)

	_cmd_full_sync = _command_server.register_command(_handle_full_sync, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)
	_cmd_diff_sync = _command_server.register_command(_handle_diff_sync, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)

	# Only with the setting, so the other commands keep their ids without it
	if _rb_send_newest_only:
		_cmd_newest_state = _command_server.register_command(_handle_newest_state, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)

	# Cleanup
	if NetworkEvents.enabled:
		NetworkEvents.on_peer_leave.connect(erase_peer)
	elif is_instance_valid(multiplayer):
		multiplayer.peer_disconnected.connect(erase_peer)

func _handle_input(sender: int, data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data

	var snapshots := _redundant_serializer.read_from(sender, _rb_input_properties, buffer, true)

	# Oldest first, so input ending a silence ends it at its oldest tick
	for i in range(snapshots.size() - 1, -1, -1):
		_ingest_input(sender, snapshots[i])

func _handle_full_state(sender: int, data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data

	var snapshot := _dense_serializer.read_from(sender, _rb_state_properties, buffer, true, _get_state_property_filter(multiplayer.get_unique_id()))

	_ingest_state(sender, snapshot)

func _handle_diff_state(sender: int, data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data

	var diff := _sparse_serializer.read_from(sender, _rb_state_properties, buffer)
	_logger.trace("Received diff state for @%d", [diff.tick])

	_ingest_state(sender, diff)

func _handle_newest_state(sender: int, data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data

	for snapshot in _ticked_serializer.read_from(sender, _rb_state_properties, buffer, NetworkRollback.history_limit):
		_ingest_state(sender, snapshot)

func _handle_full_sync(sender: int, data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data

	var snapshot := _dense_serializer.read_from(sender, _sync_state_properties, buffer, true)
	snapshot.sanitize(sender)

	NetworkHistoryServer._merge_synchronizer_state(snapshot)
	_logger.trace("Ingested sync state: %s", [snapshot])

func _handle_diff_sync(sender: int, data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data

	var snapshot := _sparse_serializer.read_from(sender, _sync_state_properties, buffer)
	snapshot.sanitize(sender)

	NetworkHistoryServer._merge_synchronizer_state(snapshot)
	_logger.trace("Ingested sync diff: %s", [snapshot])

func _make_subject_snapshot(subject: Node, tick: int, values: Dictionary) -> _Snapshot:
	var snapshot := _Snapshot.new(tick)
	for property in values:
		snapshot.set_property(subject, property, values[property])
	snapshot.set_auth(subject, true)
	return snapshot

## Return the earliest tick input is accepted for
## [br][br]
## See [signal on_input_refused].
func get_earliest_input_tick() -> int:
	if _input_max_late < 0:
		return NetworkRollback.history_start
	return maxi(NetworkTime.tick - _input_max_late, NetworkRollback.history_start)

## Return the latest tick input is accepted for
## [br][br]
## Measured from the later of the current tick and the reference clock's tick,
## so input sent in time is not refused while catching up after a hitch. States
## are not accepted past it either. See [signal on_input_refused].
func get_latest_input_tick() -> int:
	if _input_max_early < 0:
		return 1 << 62
	var now := maxi(NetworkTime.tick, NetworkTime.seconds_to_ticks(NetworkTimeSynchronizer.get_time()))
	return now + NetworkRollback.input_delay + _input_max_early

func _ingest_input(sender: int, snapshot: _Snapshot) -> void:
	snapshot.sanitize(sender)
	if not _is_input_accepted(sender, snapshot):
		return
	if not _starvation_ticks.is_empty() and not _admit_starving_input(sender, snapshot):
		return

	_logger.trace("Ingesting input: %s", [snapshot])
	if NetworkHistoryServer._merge_rollback_input(snapshot):
		NetworkPerformance.push_input_lateness(sender, NetworkTime.tick - snapshot.tick)
		_on_input.emit(snapshot)

# Input from before a stall is left to the history server to drop. Too late
# input that is already known is a redundant copy, dropped without a refusal.
func _is_input_accepted(sender: int, snapshot: _Snapshot) -> bool:
	var tick := snapshot.tick
	if snapshot.is_empty():
		return false
	if tick < NetworkRollback._history_floor:
		return true

	if tick > get_latest_input_tick():
		_refuse_input(sender, tick, "too early")
		return false

	if tick < get_earliest_input_tick():
		for subject in snapshot.get_auth_subjects():
			if not NetworkHistoryServer._rb_input_history.is_auth(tick, subject):
				_refuse_input(sender, tick, "too late")
				return false
		return false

	return true

# Track the real input of inputs with starvation; refuse what a silence
# filled, and end a silence with the first input after its start
# Return false if nothing is left of the snapshot
func _admit_starving_input(sender: int, snapshot: _Snapshot) -> bool:
	var tick := snapshot.tick
	for subject in snapshot.get_auth_subjects():
		if not _starvation_ticks.has(subject):
			continue

		if _starved_from.has(subject):
			if tick < (_starved_from[subject] as int):
				snapshot.erase_subject(subject)
				_refuse_input(sender, tick, "older than the silence it ended")
				continue
			_end_starvation(subject, tick)
		elif _fills.has(subject) and (_fills[subject] as Dictionary).get(tick, false):
			snapshot.erase_subject(subject)
			_refuse_input(sender, tick, "filled while silent")
			continue

		if not _newest_input.has(subject):
			_gap_checked[subject] = tick
		_newest_input[subject] = maxi(tick, _newest_input.get(subject, tick))
	return not snapshot.is_empty()

# Withdraw the fills of [param input] from [param tick] on, for real input
func _end_starvation(input: Node, tick: int) -> void:
	var withdrawn := []
	var fills := _fills.get(input, {}) as Dictionary
	for filled in fills.keys():
		if filled >= tick:
			withdrawn.append(filled)
			fills.erase(filled)
	NetworkHistoryServer._withdraw_input(input, tick, withdrawn, _simulation_server._get_controlled_by(input))
	_starved_from.erase(input)
	_starve_filled.erase(input)
	_gap_checked[input] = maxi(_gap_checked.get(input, tick - 1), tick - 1)
	_logger.debug("Input of %s arrives again @%d, %d fills withdrawn", [input, tick, withdrawn.size()])

# Fill the gaps and silences of inputs with starvation
# Called before the rollback loop decides its range
func _starve_inputs() -> void:
	if _starvation_ticks.is_empty():
		return

	var redundancy := NetworkRollback.input_redundancy
	var last := NetworkTime.tick - 1 # The newest tick this loop simulates
	for input in _starvation_ticks.keys():
		var input_node := input as Node
		if not _newest_input.has(input_node) or not _can_starve(input_node, last):
			continue

		var newest := _newest_input[input_node] as int
		var is_silent := _starved_from.has(input_node) or \
			newest < NetworkTime.tick - (_starvation_ticks[input_node] as int)

		# Every packet that carried a tick redundancy before the newest is older
		# than the newest one; in a silence, all of them
		var filled := _fill_gaps(input_node, newest - 1 if is_silent else newest - redundancy)

		if is_silent:
			if not _starved_from.has(input_node):
				_starved_from[input_node] = newest + 1
				_logger.debug("Input of %s silent since @%d, starving", [input_node, newest])
			for tick in range((_starve_filled.get(input_node, newest) as int) + 1, last + 1):
				if not _fill_input(input_node, tick, true):
					break
				_starve_filled[input_node] = tick
				filled += 1

		_forget_old_fills(input_node)
		NetworkPerformance.push_inputs_starved(filled)

# Return true if [param input]'s missing input may be filled up to [param tick]
func _can_starve(input: Node, tick: int) -> bool:
	if input.is_multiplayer_authority() or not _is_peer_connected(input, input.get_multiplayer_authority()):
		return false
	var controlled := _simulation_server._get_controlled_by(input)
	if controlled.is_empty() or not controlled[0].is_multiplayer_authority():
		return false
	# A node without liveness callbacks counts as alive, a despawned one is done
	return controlled.all(func(node): return RollbackLivenessServer.is_alive(node, tick))

func _fill_gaps(input: Node, to: int) -> int:
	var filled := 0
	var from := maxi((_gap_checked.get(input, to) as int) + 1, NetworkRollback.history_start)
	for tick in range(from, to + 1):
		if not NetworkHistoryServer._rb_input_history.is_auth(tick, input) and _fill_input(input, tick, false):
			filled += 1
	_gap_checked[input] = maxi(_gap_checked.get(input, to), to)
	return filled

# Fill [param input] at [param tick] from its input before; with [param is_starved],
# after the input node's own [code]_rollback_starve()[/code]
func _fill_input(input: Node, tick: int, is_starved: bool) -> bool:
	var controlled := _simulation_server._get_controlled_by(input)
	if not controlled.all(func(node): return RollbackLivenessServer.is_alive(node, tick)):
		return false
	var previous := NetworkHistoryServer._rb_input_history.get_latest_snapshot(tick, input)
	if previous == null:
		return false

	var snapshot := _Snapshot.new(tick)
	if is_starved:
		previous.apply()
		if input.has_method("_rollback_starve"):
			input._rollback_starve(tick)
		for property in _rb_input_properties.get_properties_of_raw(input):
			snapshot.set_property(input, property, input.get_indexed(property))
	else:
		for property in _rb_input_properties.get_properties_of_raw(input):
			var value = previous.get_value(property)
			snapshot.set_property(input, property, value.duplicate(true) if value is Array or value is Dictionary else value)
	snapshot.set_auth(input, true)

	if not NetworkHistoryServer._merge_rollback_input(snapshot):
		return false
	if not _fills.has(input):
		_fills[input] = {}
	_fills[input][tick] = is_starved
	_logger.trace("Filled input @%d: %s", [tick, snapshot])
	_on_input.emit(snapshot)
	return true

func _forget_old_fills(input: Node) -> void:
	var fills := _fills.get(input, {}) as Dictionary
	var start := NetworkRollback.history_start
	for tick in fills.keys():
		if tick < start:
			fills.erase(tick)

func _refuse_input(sender: int, tick: int, reason: String) -> void:
	_logger.debug("Refusing input @%d from #%d, %s", [tick, sender, reason])
	NetworkPerformance.push_input_refused(sender)
	on_input_refused.emit(sender, tick)

func _ingest_state(sender: int, snapshot: _Snapshot) -> void:
	snapshot.sanitize(sender)

	if snapshot.tick > get_latest_input_tick():
		_logger.debug("Refusing state @%d from #%d, too early", [snapshot.tick, sender])
		NetworkPerformance.push_state_refused()
		return

	for subject in snapshot.get_subjects():
		if snapshot.is_auth(subject) and snapshot.tick > _rb_latest_received_state.get(subject, -1):
			_rb_latest_received_state[subject] = snapshot.tick

	if NetworkHistoryServer._merge_rollback_state(snapshot):
		_on_state.emit(snapshot)
	_logger.trace("Ingested state: %s", [snapshot])

# What a peer was last sent of a subject's state: the tick and all the values
# it holds after it, which the next diff is relative to. Never modified, so
# peers sent the same share one
class _SentState extends RefCounted:
	var tick: int
	var values: Dictionary

	func _init(p_tick: int, p_values: Dictionary) -> void:
		tick = p_tick
		values = p_values
