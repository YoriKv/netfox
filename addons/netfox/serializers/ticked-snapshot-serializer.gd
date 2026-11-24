extends _BaseSnapshotSerializer
class_name _TickedSnapshotSerializer

# Serializes the states of several subjects, each of a tick of its own: every
# packet starts with the newest tick, then each subject's reference, how many
# ticks its state is older than the newest, and its properties as in a sparse
# snapshot - the changed ones, or all for a full state

static func _static_init() -> void:
	_logger = NetfoxLogger._for_netfox("TickedSnapshotSerializer")

# [param entries] are [subject, tick, values], values mapping some of the
# subject's [param properties] to their values, none of them newer than
# [param newest_tick]
# Pass the same [param frames] to write for several peers: each subject's data
# is encoded once for all entries holding the same tick and values of it, and
# only its reference per peer
func write_for(peer: int, newest_tick: int, entries: Array, properties: _PropertyPool, frames: Dictionary = {}) -> Array[PackedByteArray]:
	var packet_buffer := _PacketBuffer.new(max_packet_size)
	var frame_buffer := StreamPeerBuffer.new()

	packet_buffer.packet_setup = func(packet: StreamPeerBuffer):
		packet.put_u32(newest_tick)

	for entry in entries:
		var node := entry[0] as Node
		var age := newest_tick - (entry[1] as int)
		var values := entry[2] as Dictionary
		assert(node.is_multiplayer_authority(), "Trying to serialize state for non-owned node!")
		assert(age >= 0, "Trying to serialize state newer than the packet's tick!")

		frame_buffer.clear()
		if _write_identifier(node, peer, frame_buffer) != OK:
			continue

		var key := [age, values]
		var frame_data := _find_frame(frames, node, key)
		if frame_data.is_empty():
			frame_data = _encode_frame(node, age, values, properties)
			_keep_frame(frames, node, key, frame_data)
		frame_buffer.put_data(frame_data)

		packet_buffer.push(frame_buffer.data_array)

	return packet_buffer.finish()

# Return the snapshots read, one per tick, oldest first. A subject older than
# [param max_age] ticks, or with properties it does not have, ends the read:
# the rest of the packet cannot be trusted
func read_from(peer: int, properties: _PropertyPool, buffer: StreamPeerBuffer, max_age: int) -> Array[_Snapshot]:
	var netref := NetworkSchemas._netref()
	var varuint := NetworkSchemas.varuint()
	var varbits := NetworkSchemas._varbits()
	var node_buffer := StreamPeerBuffer.new()

	var newest_tick := buffer.get_u32()
	var snapshots := {} # tick to _Snapshot

	while buffer.get_available_bytes() > 0:
		var idref := netref.decode(buffer) as _NetworkIdentityReference
		var age := varuint.decode(buffer) as int
		var node_data_size := varuint.decode(buffer) as int
		var changed_bits := varbits.decode(buffer) as _Bitset
		node_buffer.data_array = buffer.get_partial_data(node_data_size)[1]

		if age > max_age or age > newest_tick:
			_logger.warning("Received state %d ticks old from #%s, dropping the rest of the packet", [age, peer])
			break

		var identifier := _get_identity_server()._resolve_reference(peer, idref)
		if not identifier:
			if _get_identity_server()._is_recently_deregistered(idref):
				_logger.debug("Received reference to deregistered identity %s from #%s, skipping data", [idref, peer])
			else:
				_logger.warning("Received unknown identity reference %s from #%s, skipping data", [idref, peer])
			continue
		var node := identifier.get_subject() as Node

		var node_props := properties.get_properties_of(node)
		var indices := changed_bits.get_set_indices()
		if indices.any(func(idx): return idx >= node_props.size()):
			_logger.warning("Received state of unknown properties of %s from #%s, dropping the rest of the packet", [node, peer])
			break

		var tick := newest_tick - age
		if not snapshots.has(tick):
			snapshots[tick] = _Snapshot.new(tick)
		var snapshot := snapshots[tick] as _Snapshot
		for idx in indices:
			snapshot.set_property(node, node_props[idx], _read_property(node, node_props[idx], node_buffer))
		snapshot.set_auth(node, true)

	var ticks := snapshots.keys()
	ticks.sort()
	var result: Array[_Snapshot] = []
	for tick in ticks:
		result.append(snapshots[tick])
	return result

func _encode_frame(node: Node, age: int, values: Dictionary, properties: _PropertyPool) -> PackedByteArray:
	var varuint := NetworkSchemas.varuint()
	var varbits := NetworkSchemas._varbits()
	var node_buffer := StreamPeerBuffer.new()
	var data_buffer := StreamPeerBuffer.new()

	var node_props := properties.get_properties_of_raw(node)
	var changed_bits := _Bitset.new(node_props.size())
	for i in node_props.size():
		var property := node_props[i] as NodePath
		if not values.has(property):
			continue
		changed_bits.set_bit(i)
		_write_property(node, property, values[property], node_buffer)

	varuint.encode(age, data_buffer)
	varuint.encode(node_buffer.data_array.size(), data_buffer)
	varbits.encode(changed_bits, data_buffer)
	data_buffer.put_data(node_buffer.data_array)
	return data_buffer.data_array
