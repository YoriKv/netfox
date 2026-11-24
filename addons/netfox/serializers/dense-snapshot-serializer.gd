extends _BaseSnapshotSerializer
class_name _DenseSnapshotSerializer

static func _static_init() -> void:
	_logger = NetfoxLogger._for_netfox("DenseSnapshotSerializer")

# Pass the same [param frames] to write snapshots for several peers: each
# subject's data is encoded once for all snapshots holding the same values of
# it, after [param property_filter], and only its reference per peer
# The [param property_filter] leaves properties out; the reader must leave out
# the same ones. Given [param subjects], only those are written, in their order
func write_for(peer: int, snapshot: _Snapshot, properties: _PropertyPool, filter: Callable = _default_filter, frames: Dictionary = {}, property_filter: Callable = _default_property_filter, subjects: Array = []) -> Array[PackedByteArray]:
	var packet_buffer := _PacketBuffer.new(max_packet_size)
	var frame_buffer := StreamPeerBuffer.new()
	var node_buffer := StreamPeerBuffer.new()
	var data_buffer := StreamPeerBuffer.new()

	var varuint := NetworkSchemas.varuint()

	# Add a timestamp to every packet
	packet_buffer.packet_setup = func(packet: StreamPeerBuffer):
		packet.put_u32(snapshot.tick)

	# For each node
	for subject in (subjects if not subjects.is_empty() else properties.get_subjects_raw()):
		if not filter.call(subject): continue
		if not snapshot.is_auth(subject): continue

		var node := subject as Node
		assert(node.is_multiplayer_authority(), "Trying to serialize state for non-owned node!")
		assert(snapshot.is_auth(node), "Trying to serialize non-auth state node!")

		# Write identifier
		frame_buffer.clear()
		if _write_identifier(node, peer, frame_buffer) != OK:
			continue

		var values := {}
		for property in properties.get_properties_of_raw(node):
			if not property_filter.call(node, property): continue
			assert(snapshot.has_property(node, property), "Trying to serialize missing property %s on subject %s!" % [property, node])
			values[property] = snapshot.get_property(node, property)

		var frame_data := _find_frame(frames, node, values)
		if frame_data.is_empty():
			node_buffer.clear()
			data_buffer.clear()

			# Write properties as-is, in the property pool's order
			# First into a buffer, so we can start with the state size
			for property in values:
				_write_property(node, property, values[property], node_buffer)

			# Indicate state size for the node
			varuint.encode(node_buffer.data_array.size(), data_buffer)

			# Write node state
			data_buffer.put_data(node_buffer.data_array)
			frame_data = data_buffer.data_array
			_keep_frame(frames, node, values, frame_data)

		frame_buffer.put_data(frame_data)

		# Write frame into output buffer
		packet_buffer.push(frame_buffer.data_array)

	return packet_buffer.finish()

func read_from(peer: int, properties: _PropertyPool, buffer: StreamPeerBuffer, is_auth: bool = true, property_filter: Callable = _default_property_filter) -> _Snapshot:
	var netref := NetworkSchemas._netref()
	var varuint := NetworkSchemas.varuint()
	var node_buffer := StreamPeerBuffer.new()

	# Read tick
	var tick := buffer.get_u32()
	var snapshot := _Snapshot.new(tick)

	while buffer.get_available_bytes() > 0:
		# Read identity reference, data size, and data
		var idref := netref.decode(buffer) as _NetworkIdentityReference
		var node_data_size := varuint.decode(buffer) as int
		node_buffer.data_array = buffer.get_partial_data(node_data_size)[1]

		# Resolve to identifier
		var identifier := _get_identity_server()._resolve_reference(peer, idref)
		if not identifier:
			# TODO(#563): Handle unknown IDs gracefully
			if _get_identity_server()._is_recently_deregistered(idref):
				_logger.debug("Received reference to deregistered identity %s from #%s, skipping data", [idref, peer])
			else:
				_logger.warning("Received unknown identity reference %s from #%s, skipping data", [idref, peer])
			continue
		var node := identifier.get_subject() as Node
		assert(is_instance_valid(node), "Where node?")

		# Read properties
		for property in properties.get_properties_of(node):
			if not property_filter.call(node, property): continue
			if node_buffer.get_available_bytes() == 0: break

			var value := _read_property(node, property, node_buffer)
			snapshot.set_property(node, property, value)
		snapshot.set_auth(node, is_auth)

	return snapshot
