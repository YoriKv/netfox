extends Node
class_name _NetworkHistoryServer

# @public class

## Tracks the history of objects' properties
##
## Specifically, history is stored for rollback state properties, rollback input
## properties, and synchronized state properties.
## [br][br]
## Keeping history lets rollback restore earlier game states for resimulation,
## and enables [_NetworkSynchronizationServer] to send diff states by comparing
## against historical data.

var _rb_input_properties := _PropertyPool.new()
var _rb_state_properties := _PropertyPool.new()
var _sync_state_properties := _PropertyPool.new()

var _rb_history_size := NetworkRollback.history_limit
var _sync_history_size := ProjectSettings.get_setting("netfox/state_synchronizer/history_limit", 64) as int

var _ignored_subjects := _Set.new()

# Input subjects whose input for a tick was received or recorded since the last
# rollback loop, for the performance monitors
var _new_inputs := {} # tick to _Set of input subjects

# Source of truth for history
var _rb_input_history := _PerObjectHistory.new(_rb_history_size)
var _rb_state_history := _PerObjectHistory.new(_rb_history_size)
var _sync_history := _PerObjectHistory.new(_sync_history_size)

# Cached snapshots for syncing
var _rb_input_snapshots := _HistoryBuffer.new(_rb_history_size)
var _rb_state_snapshots := _HistoryBuffer.new(_rb_history_size)
var _sync_state_snapshots := _HistoryBuffer.new(_sync_history_size)

static var _logger := NetfoxLogger._for_netfox("NetworkHistoryServer")

## Register a rollback state property
func register_rollback_state(node: Node, property: NodePath) -> void:
	_rb_state_properties.add(node, property)

## Deregister a rollback state property
func deregister_rollback_state(node: Node, property: NodePath) -> void:
	_rb_state_properties.erase(node, property)

## Register a rollback input property
func register_rollback_input(node: Node, property: NodePath) -> void:
	_rb_input_properties.add(node, property)

## Deregister a rollback input property
func deregister_rollback_input(node: Node, property: NodePath) -> void:
	_rb_input_properties.erase(node, property)

## Register a synchronized state property
func register_sync_state(node: Node, property: NodePath) -> void:
	_sync_state_properties.add(node, property)

## Deregister a synchronized state property
func deregister_sync_state(node: Node, property: NodePath) -> void:
	_sync_state_properties.erase(node, property)

## Deregister a node, no longer tracking any property it had registered using
## any of the [code]register_*()[/code] methods
func deregister(node: Node) -> void:
	# Deregister properties
	_rb_state_properties.erase_subject(node)
	_rb_input_properties.erase_subject(node)
	_sync_state_properties.erase_subject(node)

	# Erase from per-object history
	_rb_state_history.erase_subject(node)
	_rb_input_history.erase_subject(node)
	_sync_history.erase_subject(node)

	# Erase from per-tick history
	for history in [_rb_state_snapshots, _rb_input_snapshots, _sync_state_snapshots]:
		for value in history.values():
			var snapshot := value as _Snapshot
			snapshot.erase_subject(node)

## Forget all recorded history, while keeping the registered properties
## [br][br]
## History is indexed by tick, so data from a previous session must not carry
## over to the next one. Called by [method _NetworkTime.stop].
func reset() -> void:
	_rb_input_history = _PerObjectHistory.new(_rb_history_size)
	_rb_state_history = _PerObjectHistory.new(_rb_history_size)
	_sync_history = _PerObjectHistory.new(_sync_history_size)

	_rb_input_snapshots = _HistoryBuffer.new(_rb_history_size)
	_rb_state_snapshots = _HistoryBuffer.new(_rb_history_size)
	_sync_state_snapshots = _HistoryBuffer.new(_sync_history_size)

	_ignored_subjects.clear()
	_new_inputs.clear()

## Do not record [param subject]
## [br][br]
## Can be used in [code]_rollback_tick()[/code] in case node prediction is
## enabled, but state can't be reasonably predicted.
## [br][br]
## Subjects stay ignored until [method flush_ignores] is called. This is done
## by default after every rollback tick.
func ignore(subject: Node) -> void:
	_ignored_subjects.add(subject)

## Clear the list of ignored subjects
## [br][br]
## Calling this method undoes all previous [method ignore] calls.
func flush_ignores() -> void:
	_ignored_subjects.clear()

## Return the latest tick where any of the [param subjects] had rollback
## state data available
func get_latest_state_tick_for(subjects: Array, tick: int) -> int:
	return _get_latest_for(subjects, tick, _rb_state_history)

## Return how old is the latest rollback state data for any of the
## [param subjects], in ticks
func get_state_age_for(subjects: Array, tick: int) -> int:
	var latest_state := get_latest_state_tick_for(subjects, tick)
	if latest_state < 0:
		return -1
	else:
		return tick - latest_state

## Return the latest tick where any of the [param subjects] had rollback
## input data available
func get_latest_input_for(subjects: Array, tick: int) -> int:
	return _get_latest_for(subjects, tick, _rb_input_history)

## Return how old is the latest rollback input data for any of the
## [param subjects], in ticks
func get_input_age_for(subjects: Array, tick: int) -> int:
	var latest_input := get_latest_input_for(subjects, tick)
	if latest_input < 0:
		return -1
	else:
		return tick - latest_input

## Return the rollback input recorded for [param subject] at [param tick]
## [br][br]
## The result maps the subject's property paths to their values. It is empty if
## no authoritative input was recorded for [param subject] at [param tick].
func get_rollback_input_at(subject: Node, tick: int) -> Dictionary:
	return _get_auth_values(_rb_input_history, subject, tick)

## Return the rollback state recorded for [param subject] at [param tick]
## [br][br]
## The result maps the subject's property paths to their values. It is empty if
## no authoritative state was recorded for [param subject] at [param tick].
func get_rollback_state_at(subject: Node, tick: int) -> Dictionary:
	return _get_auth_values(_rb_state_history, subject, tick)

## Record currently registered rollback state properties for [param subject] at
## [param tick].
func push_rollback_state(subject: Node, tick: int) -> void:
	var subject_snapshot := _rb_state_history.ensure_snapshot(tick, subject, false)
	if subject_snapshot == null:
		_logger.warning("Dropping seeded state @%d for subject %s as out-of-bounds", [tick, subject])
		return

	var snapshot := _rb_state_snapshots.get_at(tick, _Snapshot.new(tick)) as _Snapshot
	if not _rb_state_snapshots.has_at(tick):
		_rb_state_snapshots.set_at(tick, snapshot)

	var is_auth := subject.is_multiplayer_authority()
	subject_snapshot.record_properties(
		_rb_state_properties.get_properties_of_raw(subject),
		snapshot,
		is_auth
	)

func _record_rollback_input(tick: int) -> void:
	_record(tick, _rb_input_history, _rb_input_snapshots, _rb_input_properties, true, func(subject: Node):
		return subject.is_multiplayer_authority()
	)

	if NetworkPerformance._enabled:
		for subject in _rb_input_properties.get_subjects_raw():
			if (subject as Node).is_multiplayer_authority():
				_add_new_input(tick, subject)

func _record_rollback_state(tick: int) -> void:
	var input_snapshot := _get_rollback_input_snapshot(tick - 1)

	_record(tick, _rb_state_history, _rb_state_snapshots, _rb_state_properties, false, func(subject: Node):
		if not subject.is_multiplayer_authority():
			return false
		if RollbackSimulationServer._is_predicting(input_snapshot, subject):
			return false
		return true
	)

func _record_sync_state(tick: int) -> void:
	_record(tick, _sync_history, _sync_state_snapshots, _sync_state_properties, true, func(subject: Node):
		return subject.is_multiplayer_authority()
	)

func _restore_rollback_input(tick: int) -> bool:
	return _restore_latest(tick, _rb_input_history)

func _restore_rollback_state(tick: int) -> bool:
	return _restore_latest(tick, _rb_state_history)

func _restore_synchronizer_state(tick: int) -> bool:
	return _restore_latest(tick, _sync_history)

func _get_rollback_input_snapshot(tick: int) -> _Snapshot:
	return _rb_input_snapshots.get_at(tick)

func _get_rollback_state_snapshot(tick: int) -> _Snapshot:
	return _rb_state_snapshots.get_at(tick)

func _get_synchronizer_state_snapshot(tick: int) -> _Snapshot:
	return _sync_state_snapshots.get_at(tick)

func _merge_rollback_input(snapshot: _Snapshot) -> bool:
	if not _can_merge_tick(snapshot.tick, _rb_input_history):
		return false

	if NetworkPerformance._enabled:
		for subject in snapshot.get_auth_subjects():
			if not _rb_input_history.is_auth(snapshot.tick, subject):
				_add_new_input(snapshot.tick, subject)

	_merge_snapshot(snapshot, _rb_input_snapshots, true)
	return _merge_history(snapshot, _rb_input_history, true)

func _merge_rollback_state(snapshot: _Snapshot) -> bool:
	if not _can_merge_tick(snapshot.tick, _rb_state_history):
		return false

	var corrections := _find_corrections(snapshot)

	_merge_snapshot(snapshot, _rb_state_snapshots)
	var changed_subjects := []
	var has_updated := _merge_history(snapshot, _rb_state_history, false, changed_subjects)
	if not NetworkRollback._resimulate_on_remote_state:
		has_updated = _carry_remote_states(snapshot.tick, changed_subjects)

	for correction in corrections:
		NetworkRollback.on_correction.emit(correction[0], snapshot.tick, correction[1])
	return has_updated

# A changed state of a node this peer does not simulate starts no resimulation:
# its records after [param tick] are rewritten as resimulating would record them
# instead. Return true if a node this peer simulates changed
func _carry_remote_states(tick: int, changed_subjects: Array) -> bool:
	var has_updated := false
	for subject in changed_subjects:
		if RollbackSimulationServer._is_simulated_locally(subject):
			has_updated = true
			continue

		for carried_tick in _rb_state_history.carry_forward(tick, subject):
			var tick_snapshot := _rb_state_snapshots.get_at(carried_tick) as _Snapshot
			if tick_snapshot == null:
				tick_snapshot = _Snapshot.new(carried_tick)
				_rb_state_snapshots.set_at(carried_tick, tick_snapshot)
			var record := _rb_state_history.get_snapshot(carried_tick, subject)
			for property in record.properties():
				tick_snapshot.set_property(subject, property, record.get_value(property))
			tick_snapshot.set_auth(subject, false)
	return has_updated

# Return [subject, properties] for each subject simulated here whose recorded
# state at the snapshot's tick differs from the snapshot, counting them
# Does nothing if neither the signal nor the monitors need it
func _find_corrections(snapshot: _Snapshot) -> Array:
	var result := []
	var is_signal_connected := not NetworkRollback.on_correction.get_connections().is_empty()
	if not is_signal_connected and not NetworkPerformance._enabled:
		return result

	var count := 0
	for subject in snapshot.get_auth_subjects():
		var recorded := _rb_state_history.get_snapshot(snapshot.tick, subject)
		if recorded == null or not RollbackSimulationServer._is_simulated_locally(subject):
			continue

		var properties := {}
		for property in snapshot.get_subject_properties(subject):
			if not recorded.has_value(property):
				continue
			var recorded_value = recorded.get_value(property)
			var received_value = snapshot.get_property(subject, property)
			if recorded_value != received_value:
				properties[property] = [recorded_value, received_value]

		if properties.is_empty():
			continue
		count += 1
		if is_signal_connected:
			result.append([subject, properties])

	NetworkPerformance.push_corrections(count)
	return result

# Remove the input of [param subject] from [param from_tick] on, filled by
# starvation at [param ticks], which real input replaces; the states simulated
# from those ticks for the [param controlled] nodes are no longer authoritative
func _withdraw_input(subject: Object, from_tick: int, ticks: Array, controlled: Array) -> void:
	_rb_input_history.trim_subject(subject, from_tick)
	for tick in ticks:
		var input_snapshot := _rb_input_snapshots.get_at(tick) as _Snapshot
		if input_snapshot:
			input_snapshot.erase_subject(subject)
		var state_snapshot := _rb_state_snapshots.get_at(tick + 1) as _Snapshot
		for node in controlled:
			var recorded := _rb_state_history.get_snapshot(tick + 1, node)
			if recorded:
				recorded.set_auth(false)
			if state_snapshot:
				state_snapshot.set_auth(node, false)

func _add_new_input(tick: int, subject: Object) -> void:
	if not _new_inputs.has(tick):
		_new_inputs[tick] = _Set.new()
	(_new_inputs[tick] as _Set).add(subject)

# Return true if input for [param subject] at [param tick] was received or
# recorded since the last rollback loop. Only tracked with performance
# monitoring enabled.
func _is_input_new(tick: int, subject: Object) -> bool:
	return _new_inputs.has(tick) and (_new_inputs[tick] as _Set).has(subject)

func _clear_new_inputs() -> void:
	_new_inputs.clear()

func _merge_synchronizer_state(snapshot: _Snapshot) -> bool:
	if not _can_merge_tick(snapshot.tick, _sync_history):
		return false
	_merge_snapshot(snapshot, _sync_state_snapshots, true)
	return _merge_history(snapshot, _sync_history)

func _record(tick: int, history: _PerObjectHistory, snapshots: _HistoryBuffer, property_pool: _PropertyPool, only_auth: bool, auth_filter: Callable) -> void:
	var snapshot := snapshots.get_at(tick, _Snapshot.new(tick)) as _Snapshot
	if not snapshots.has_at(tick):
		snapshots.set_at(tick, snapshot)

	history.record_subjects(
		tick,
		property_pool.get_subjects_raw(),
		property_pool,
		snapshot,
		only_auth,
		auth_filter,
		history == _rb_state_history,
		_ignored_subjects
	)
	if history == _rb_input_history:
		_logger.trace("Recorded input @%d: %s", [tick, snapshot])
	elif history == _rb_state_history:
		_logger.trace("Recorded state @%d: %s", [tick, snapshot])

func _restore_latest(tick: int, history: _PerObjectHistory) -> bool:
	var any_applied := history.restore_latest(tick)

	if any_applied and _logger._check_log_level(NetfoxLogger.LOG_TRACE):
		if history == _rb_input_history:
			_logger.trace("Restored input @%d", [tick])
		elif history == _rb_state_history:
			_logger.trace("Restored state @%d", [tick])

	return any_applied

func _merge_snapshot(snapshot: _Snapshot, snapshots: _HistoryBuffer, reverse: bool = false) -> bool:
	var tick := snapshot.tick

	if not snapshots.has_at(snapshot.tick):
		snapshots.set_at(tick, snapshot)
		return true

	var original_snapshot := snapshots.get_at(tick) as _Snapshot
	if reverse:
		var original_subjects := original_snapshot.get_auth_subjects()
		var incoming_subjects := snapshot.get_auth_subjects()

		# Merge the original snapshot on top of the incoming
		# This prevents players from changing history, e.g. rewrite their past
		# inputs
		snapshots.set_at(tick, snapshot)
		snapshot.merge(original_snapshot)

		# Only return true if we've received inputs for a new node
		return incoming_subjects.any(func(it): return not original_subjects.has(it))
	else:
		return original_snapshot.merge(snapshot)

# Appends each subject whose values changed to [param changed_subjects]
func _merge_history(snapshot: _Snapshot, history: _PerObjectHistory, reverse: bool = false, changed_subjects: Array = []) -> bool:
	var tick := snapshot.tick
	var has_updated := false

	for subject in snapshot.get_subjects():
		var object_snapshot := history.ensure_snapshot(tick, subject, not reverse)
		if object_snapshot == null:
			_logger.warning("Snapshot being merged is out of bounds! (@%d)", [tick])
			continue

		# Never overwrite auth data
		if object_snapshot.is_auth() and not snapshot.is_auth(subject):
			continue

		var is_changed := false
		for property in snapshot.get_subject_properties(subject):
			# If merging in reverse, don't update anything that we already have
			# a value for - only accept previously unknown property values
			if reverse and object_snapshot.has_value(property):
				continue

			var original_value := object_snapshot.get_value(property)
			var new_value := snapshot.get_property(subject, property)

			object_snapshot.set_value(property, new_value)
			if not is_changed and original_value != new_value:
				is_changed = true
		object_snapshot.set_auth(snapshot.is_auth(subject))

		if is_changed:
			has_updated = true
			changed_subjects.append(subject)

	return has_updated

func _can_merge_tick(tick: int, history: _PerObjectHistory) -> bool:
	if tick >= NetworkRollback.history_start:
		return true

	# Packets queued while the main thread was stalled are expected to arrive
	# after NetworkTime has skipped past them. They cannot be merged into the
	# new contiguous history and are not an exceptional condition.
	if tick < NetworkRollback._history_floor:
		_logger.trace("Dropping snapshot @%d from before the current history floor", [tick])
		return false

	match history:
		_rb_input_history: _logger.warning("Input being merged is too old! (@%d)", [tick])
		_rb_state_history: _logger.warning("State being merged is too old! (@%d)", [tick])
		_sync_history: _logger.warning("Sync state being merged is too old! (@%d)", [tick])
		_: _logger.warning("Snapshot being merged is too old! (@%d)", [tick])
	return false

func _get_auth_values(history: _PerObjectHistory, subject: Node, tick: int) -> Dictionary:
	var result := {}
	if not history.is_auth(tick, subject):
		return result

	var snapshot := history.get_latest_snapshot(tick, subject)
	for property in snapshot.properties():
		result[property] = snapshot.get_value(property)
	return result

func _get_latest_for(subjects: Array, tick: int, history: _PerObjectHistory) -> int:
	var latest := -1

	for subject in subjects:
		var subject_latest := history.get_latest_tick(tick, subject)
		if subject_latest < 0:
			continue

		# Should we track `mini()` instead?
		latest = maxi(latest, subject_latest)

	return latest

func _get_earliest_for(subjects: Array, tick: int, history: _PerObjectHistory) -> int:
	var earliest := -1

	for subject in subjects:
		var subject_latest := history.get_latest_tick(tick, subject)
		if subject_latest < 0:
			return -1

		if earliest < 0:
			earliest = earliest
		else:
			earliest = mini(earliest, subject_latest)

	return earliest
