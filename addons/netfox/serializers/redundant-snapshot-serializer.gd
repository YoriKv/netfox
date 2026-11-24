extends _BaseSnapshotSerializer
class_name _RedundantSnapshotSerializer

# Serializes snapshots of consecutive ticks into a single packet, e.g. input
# with its redundancy
#
# Packet layout:
#   varuint     newest tick
#   u8          tick count N; the packet holds the newest tick and the N - 1
#               ticks before it
#   per subject:
#     netref    identity reference
#     varuint   size of the subject's values
#     bytes     2 bits per tick, newest tick first, 4 ticks per byte:
#               absent, values, or same as the next newer tick
#     bytes     the subject's values for each tick marked so, newest first,
#               each its properties in order
#
# The reader bounds every read, as the packet comes from a client, and drops
# a malformed packet whole.

const _CODE_ABSENT := 0
const _CODE_VALUES := 1
const _CODE_SAME := 2

const _MAX_TICKS := 255
const _MAX_VARUINT_BYTES := 5

static func _static_init() -> void:
	_logger = NetfoxLogger._for_netfox("RedundantSnapshotSerializer")

func write_for(peer: int, snapshots: Array[_Snapshot], properties: _PropertyPool) -> PackedByteArray:
	var varuint := NetworkSchemas.varuint()
	var buffer := StreamPeerBuffer.new()
	if snapshots.is_empty():
		return buffer.data_array

	var tick := snapshots[0].tick
	var count := snapshots.size()
	assert(count <= _MAX_TICKS, "Too many redundant snapshots: %d!" % [count])
	for i in count:
		assert(snapshots[i].tick == tick - i, "Redundant snapshots must be of consecutive ticks, newest first!")

	varuint.encode(tick, buffer)
	buffer.put_u8(count)

	var values_buffer := StreamPeerBuffer.new()
	var codes := PackedByteArray()
	codes.resize(_get_code_size(count))

	for subject in properties.get_subjects():
		var node := subject as Node
		var node_props := properties.get_properties_of(node)

		codes.fill(0)
		values_buffer.clear()
		var is_present := false
		var newer: _Snapshot = null

		for i in count:
			var snapshot := snapshots[i]
			if not snapshot.is_auth(node):
				newer = null
				continue

			is_present = true
			var code := _CODE_VALUES
			if newer != null and _has_same_values(node, node_props, snapshot, newer):
				code = _CODE_SAME
			else:
				for property in node_props:
					assert(snapshot.has_property(node, property), "Trying to serialize missing property %s on subject %s!" % [property, node])
					_write_property(node, property, snapshot.get_property(node, property), values_buffer)

			codes[i / 4] |= code << (2 * (i % 4))
			newer = snapshot

		if not is_present:
			continue

		if _write_identifier(node, peer, buffer) != OK:
			continue
		varuint.encode(values_buffer.get_size(), buffer)
		buffer.put_data(codes)
		buffer.put_data(values_buffer.data_array)

	if buffer.get_size() > max_packet_size:
		_logger.warning("Redundant data does not fit into a single packet! Max packet size: %d bytes", [max_packet_size])

	return buffer.data_array

## Return the snapshots in [param buffer], newest first, leaving out ticks with
## no known subject. A malformed packet is dropped whole with a warning.
func read_from(peer: int, properties: _PropertyPool, buffer: StreamPeerBuffer, is_auth: bool = true) -> Array[_Snapshot]:
	var result := [] as Array[_Snapshot]
	if buffer.get_available_bytes() == 0:
		return result

	var tick := _read_varuint(buffer)
	if tick < 0 or buffer.get_available_bytes() < 1:
		return _drop_malformed(peer, "header")
	var count := buffer.get_u8()
	if count == 0:
		return _drop_malformed(peer, "tick count")

	var snapshots := [] as Array[_Snapshot]
	for i in count:
		snapshots.append(_Snapshot.new(tick - i))

	var code_size := _get_code_size(count)
	var values_buffer := StreamPeerBuffer.new()

	while buffer.get_available_bytes() > 0:
		var idref := _read_reference(buffer)
		var values_size := _read_varuint(buffer)
		if idref == null or values_size < 0 or buffer.get_available_bytes() < code_size + values_size:
			return _drop_malformed(peer, "subject header")

		var codes := buffer.get_data(code_size)[1] as PackedByteArray
		var values_data := buffer.get_data(values_size)[1] as PackedByteArray
		if not _are_codes_valid(codes, count):
			return _drop_malformed(peer, "tick codes")

		# Resolve to identifier
		var identifier := _get_identity_server()._resolve_reference(peer, idref)
		if not identifier:
			if _get_identity_server()._is_recently_deregistered(idref):
				_logger.debug("Received reference to deregistered identity %s from #%s, skipping data", [idref, peer])
			else:
				_logger.warning("Received unknown identity reference %s from #%s, skipping data", [idref, peer])
			continue
		var node := identifier.get_subject() as Node
		var node_props := properties.get_properties_of(node)
		if node_props.is_empty():
			_logger.debug("Received data for %s from #%s with no properties to read, skipping data", [node, peer])
			continue

		values_buffer.data_array = values_data
		var values := {}
		for i in count:
			var code := (codes[i / 4] >> (2 * (i % 4))) & 0b11
			if code == _CODE_ABSENT:
				continue
			if code == _CODE_VALUES:
				if values_buffer.get_available_bytes() == 0:
					return _drop_malformed(peer, "values")
				values = {}
				for property in node_props:
					values[property] = _read_property(node, property, values_buffer)

			for property in values:
				snapshots[i].set_property(node, property, _copy_value(values[property]))
			snapshots[i].set_auth(node, is_auth)

		if values_buffer.get_position() != values_size or values_buffer.get_available_bytes() != 0:
			return _drop_malformed(peer, "values size")

	for snapshot in snapshots:
		if not snapshot.is_empty():
			result.append(snapshot)
	return result

func _has_same_values(node: Node, node_props: Array[NodePath], snapshot: _Snapshot, other: _Snapshot) -> bool:
	for property in node_props:
		if snapshot.get_property(node, property) != other.get_property(node, property):
			return false
	return true

# The first tick present must have values, and a tick can only be the same as
# a newer one present
func _are_codes_valid(codes: PackedByteArray, count: int) -> bool:
	var has_newer := false
	for i in codes.size() * 4:
		var code := (codes[i / 4] >> (2 * (i % 4))) & 0b11
		if i >= count:
			if code != _CODE_ABSENT:
				return false
			continue
		match code:
			_CODE_ABSENT: has_newer = false
			_CODE_VALUES: has_newer = true
			_CODE_SAME:
				if not has_newer:
					return false
			_: return false
	return true

func _get_code_size(count: int) -> int:
	return (count + 3) / 4

# Values shared between ticks must not be the same collection
func _copy_value(value: Variant) -> Variant:
	if value is Array or value is Dictionary:
		return value.duplicate(true)
	return value

# Return -1 if the buffer ends or the value is too long
func _read_varuint(buffer: StreamPeerBuffer) -> int:
	var value := 0
	for i in _MAX_VARUINT_BYTES:
		if buffer.get_available_bytes() == 0:
			return -1
		var byte := buffer.get_u8()
		value |= (byte & 0x7F) << (7 * i)
		if byte & 0x80 == 0:
			return value
	return -1

# Return null if the buffer ends before the reference does
func _read_reference(buffer: StreamPeerBuffer) -> _NetworkIdentityReference:
	var id := _read_varuint(buffer)
	if id < 0:
		return null
	if id > 0:
		return _NetworkIdentityReference.of_id(id)

	var data := buffer.data_array
	var start := buffer.get_position()
	var end := data.find(0, start)
	if end < 0:
		return null
	buffer.seek(end + 1)
	return _NetworkIdentityReference.of_full_name(data.slice(start, end).get_string_from_utf8())

func _drop_malformed(peer: int, part: String) -> Array[_Snapshot]:
	_logger.warning("Dropping malformed packet from #%s, invalid %s", [peer, part])
	return [] as Array[_Snapshot]
