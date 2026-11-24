extends RefCounted
class_name _PerObjectHistory

# Stores a per-object history of ObjectSnapshots
# Each managed object has its own timeline of snapshots

var _history_size: int
var _data := {} # Object to _HistoryBuffer
var _subjects: Array[Object] = []

static var _logger := NetfoxLogger._for_netfox("PerObjectHistory")

func _init(p_history_size: int) -> void:
	_history_size = p_history_size

func subjects() -> Array[Object]:
	var result: Array[Object] = []
	result.assign(_subjects)
	return result

func subjects_raw() -> Array:
	return _subjects

func is_auth(tick: int, subject: Object) -> bool:
	if not _data.has(subject):
		return false

	var history := _data[subject] as _HistoryBuffer
	if not history.has_at(tick):
		return false

	var snapshot := history.get_at(tick) as _ObjectSnapshot
	return snapshot.is_auth()

func erase_subject(subject: Object) -> void:
	if _data.erase(subject):
		_subjects.erase(subject)

func ensure_snapshot(tick: int, subject: Object, carry_forward: bool) -> _ObjectSnapshot:
	var history: _HistoryBuffer
	if _data.has(subject):
		history = _data[subject]
	else:
		history = _HistoryBuffer.new(_history_size)
		_data[subject] = history
		_subjects.append(subject)

	if not history.has_at(tick):
		if carry_forward and history.has_latest_at(tick):
			history.set_at(tick, history.get_latest_at(tick).duplicate())
		else:
			history.set_at(tick, _ObjectSnapshot.new(subject))

	# NOTE: May return null if tick too old
	return history.get_at(tick) as _ObjectSnapshot

func restore_latest(tick: int) -> bool:
	var any_applied := false
	for subject in _subjects:
		var history := _data[subject] as _HistoryBuffer
		if not history.has_latest_at(tick):
			continue
		var snapshot := history.get_latest_at(tick) as _ObjectSnapshot
		if snapshot:
			snapshot.apply()
			any_applied = true
	return any_applied

# Rewrite the non-authoritative snapshots of [param subject] after [param tick],
# up to its next authoritative one, as a rollback loop that does not simulate
# [param subject] records them: each a copy of the snapshot restored before it.
# Ticks after which the subject is dead are skipped, as recording does.
# Returns the ticks rewritten
func carry_forward(tick: int, subject: Object) -> Array[int]:
	var result: Array[int] = []
	if not _data.has(subject):
		return result

	var history := _data[subject] as _HistoryBuffer
	for carried_tick in range(tick + 1, history.get_latest_index() + 1):
		var snapshot := history.get_at(carried_tick) as _ObjectSnapshot
		if snapshot and snapshot.is_auth():
			break
		if not RollbackLivenessServer.is_alive(subject, carried_tick - 1):
			continue

		var previous := history.get_latest_at(carried_tick - 1) as _ObjectSnapshot
		if snapshot == null:
			snapshot = _ObjectSnapshot.new(subject)
			history.set_at(carried_tick, snapshot)
		snapshot.copy_values(previous)
		result.append(carried_tick)
	return result

# Remove the snapshots of [param subject] from [param tick] on
func trim_subject(subject: Object, tick: int) -> void:
	if _data.has(subject):
		(_data[subject] as _HistoryBuffer).trim(tick)

# Return the snapshot recorded for exactly [param tick], or null
func get_snapshot(tick: int, subject: Object) -> _ObjectSnapshot:
	if not _data.has(subject):
		return null
	return (_data[subject] as _HistoryBuffer).get_at(tick) as _ObjectSnapshot

func get_latest_snapshot(tick: int, subject: Object) -> _ObjectSnapshot:
	if not _data.has(subject):
		return null

	var history := _data[subject] as _HistoryBuffer
	if not history.has_latest_at(tick):
		return null

	return history.get_latest_at(tick) as _ObjectSnapshot

# Return the newest tick at or before [param tick], and not before
# [param floor], with an authoritative snapshot of [param subject], or -1
func get_latest_auth_tick(tick: int, subject: Object, floor: int) -> int:
	if not _data.has(subject):
		return -1

	var history := _data[subject] as _HistoryBuffer
	var at := tick
	while at >= floor:
		var index := history.get_latest_index_at(at)
		if index < floor:
			return -1
		var snapshot := history.get_at(index) as _ObjectSnapshot
		if snapshot == null:
			return -1
		if snapshot.is_auth():
			return index
		at = index - 1
	return -1

func get_latest_tick(tick: int, subject: Object) -> int:
	if not _data.has(subject):
		return -1

	var history := _data[subject] as _HistoryBuffer
	if not history.has_latest_at(tick):
		return -1

	return history.get_latest_index_at(tick)

func record_subjects(tick: int, subjects: Array, property_pool: _PropertyPool, tick_snapshot: _Snapshot, only_auth: bool, auth_filter: Callable, check_liveness: bool, ignored: _Set) -> void:
	for subject in subjects:
		assert(subject is Node, "Only nodes supported for now!")

		if check_liveness and not RollbackLivenessServer.is_alive(subject, tick - 1):
			continue
		if ignored.has(subject):
			continue

		var is_auth: bool = auth_filter.call(subject)
		if only_auth and not is_auth:
			continue
		if not is_auth and is_auth(tick, subject):
			continue

		var subject_snapshot := ensure_snapshot(tick, subject, false)
		if subject_snapshot == null:
			_logger.warning("Dropping recorded tick @%d for subject %s as out-of-bounds", [tick, subject])
			continue

		var properties := property_pool.get_properties_of_raw(subject)
		assert(not properties.is_empty(), "Subject present in property pool without properties! Please report a bug!")
		subject_snapshot.record_properties(properties, tick_snapshot, is_auth)

func set_property(tick: int, subject: Object, property: NodePath, value: Variant) -> void:
	var history: _HistoryBuffer
	if _data.has(subject):
		history = _data[subject]
	else:
		history = _HistoryBuffer.new(_history_size)
		_data[subject] = history
		_subjects.append(subject)

	if not history.has_at(tick):
		history.set_at(tick, _ObjectSnapshot.new(subject))

	var snapshot := history.get_at(tick) as _ObjectSnapshot
	snapshot.set_value(property, value)

func has_property(tick: int, subject: Object, property: NodePath) -> bool:
	if not _data.has(subject):
		return false

	var history := _data[subject] as _HistoryBuffer
	if not history.has_at(tick):
		return false

	var snapshot := history.get_at(tick) as _ObjectSnapshot
	return snapshot.has_value(property)

func get_property(tick: int, subject: Object, property: NodePath, default: Variant = null) -> Variant:
	if not _data.has(subject):
		return default

	var history := _data[subject] as _HistoryBuffer
	if not history.has_at(tick):
		return default

	var snapshot := history.get_at(tick) as _ObjectSnapshot
	return snapshot.get_value(property, default)
