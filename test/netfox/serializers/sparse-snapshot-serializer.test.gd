extends SnapshotSerializerTest

func get_suite_name() -> String:
	return "SparseSnapshotSerializer"

func suite() -> void:
	test("should deserialize to same", func():
		var schema := _NetworkSchema.new()
		var serializer := _SparseSnapshotSerializer.new(schema)

		var subject := Node3D.new()
		Vest.get_tree().root.add_child.call_deferred(subject)
		await subject.ready
		NetworkIdentityServer.register_node(subject)

		var snapshot := _Snapshot.of(0, [
			[subject, "position", Vector3.ZERO],
			[subject, "quaternion", Quaternion.from_euler(Vector3.ONE)],
			[subject, "scale", Vector3.ONE]
		], [subject])

		var props := _PropertyPool.of([
			[subject, "position"],
			[subject, "quaternion"],
			[subject, "scale"]
		])

		var packets := serializer.write_for(1, snapshot, props)
		var serialized := packets[0]
		var deserialized := serializer.read_from(1, props, to_buffer(serialized))

		expect_equal(packets.size(), 1)
		expect_equal(deserialized, snapshot)

		Vest.message("Serialized %d props to %d bytes" % [snapshot.size(), serialized.size()])
	)

	test("should ignore unknown identifiers", func():
		var schema := _NetworkSchema.new()
		var writer_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())
		var reader_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())

		Vest.get_tree().root.add_child.call_deferred(writer_identity_server)
		Vest.get_tree().root.add_child.call_deferred(reader_identity_server)
		await writer_identity_server.ready; await reader_identity_server.ready

		var writer_serializer := _SparseSnapshotSerializer.new(schema, writer_identity_server)
		var reader_serializer := _SparseSnapshotSerializer.new(schema, reader_identity_server)

		var known_subject := await get_subject()
		var unknown_subject := await get_subject()

		var writer_props := _PropertyPool.of([[known_subject, "position"], [unknown_subject, "position"]])
		var reader_props := _PropertyPool.of([[known_subject, "position"]])

		writer_identity_server.register_node(known_subject)
		writer_identity_server.register_node(unknown_subject)

		reader_identity_server.register_node(known_subject)

		var snapshot := _Snapshot.of(0, [
			[unknown_subject, "position", Vector3.ZERO],
			[known_subject, "position", Vector3.ZERO]
		], [known_subject, unknown_subject])

		var expected := _Snapshot.of(0, [
			[known_subject, "position", Vector3.ZERO]
		], [known_subject])

		var packets := writer_serializer.write_for(1, snapshot, writer_props)
		var serialized := packets[0]
		var deserialized := reader_serializer.read_from(1, reader_props, to_buffer(serialized))

		expect_equal(packets.size(), 1)
		expect_equal(deserialized, expected)
	)

	test("should read on past unknown identifiers", func():
		var schema := _NetworkSchema.new()
		var writer_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())
		var reader_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())

		Vest.get_tree().root.add_child.call_deferred(writer_identity_server)
		Vest.get_tree().root.add_child.call_deferred(reader_identity_server)
		await writer_identity_server.ready; await reader_identity_server.ready

		var writer_serializer := _SparseSnapshotSerializer.new(schema, writer_identity_server)
		var reader_serializer := _SparseSnapshotSerializer.new(schema, reader_identity_server)

		var known_subject := await get_subject()
		var unknown_subject := await get_subject()

		# The unknown subject is written first
		var writer_props := _PropertyPool.of([[unknown_subject, "position"], [known_subject, "position"]])
		var reader_props := _PropertyPool.of([[known_subject, "position"]])

		writer_identity_server.register_node(known_subject)
		writer_identity_server.register_node(unknown_subject)

		reader_identity_server.register_node(known_subject)

		var snapshot := _Snapshot.of(0, [
			[unknown_subject, "position", Vector3.ONE],
			[known_subject, "position", Vector3.UP]
		], [known_subject, unknown_subject])

		var expected := _Snapshot.of(0, [
			[known_subject, "position", Vector3.UP]
		], [known_subject])

		var packets := writer_serializer.write_for(1, snapshot, writer_props)
		var deserialized := reader_serializer.read_from(1, reader_props, to_buffer(packets[0]))

		expect_equal(packets.size(), 1)
		expect_equal(deserialized, expected)

		for identity_server in [writer_identity_server, reader_identity_server]:
			identity_server._command_server.free()
			identity_server.queue_free()
		known_subject.queue_free()
		unknown_subject.queue_free()
	)

	test("should share a subject's frame only between snapshots with the same values of it", func():
		var serializer := _SparseSnapshotSerializer.new(_NetworkSchema.new())

		var subject := await get_subject()
		var other := await get_subject()
		NetworkIdentityServer.register_node(subject)
		NetworkIdentityServer.register_node(other)

		var props := _PropertyPool.of([
			[subject, "position"], [subject, "scale"],
			[other, "position"], [other, "scale"]
		])
		var snapshots := [
			_Snapshot.of(0, [[subject, "position", Vector3.ONE], [subject, "scale", Vector3.ONE],
				[other, "position", Vector3.UP], [other, "scale", Vector3.ONE]], [subject, other]),
			_Snapshot.of(0, [[subject, "position", Vector3.ONE], [subject, "scale", Vector3.ONE],
				[other, "position", Vector3.DOWN], [other, "scale", Vector3.ONE]], [subject, other])
		]

		var frames := {}
		for snapshot in snapshots:
			var shared := serializer.write_for(1, snapshot, props, _BaseSnapshotSerializer._default_filter, frames)
			expect_equal(shared, serializer.write_for(1, snapshot, props))
		expect_equal(frames[subject].size(), 1, "Encoded once for the same values")
		expect_equal(frames[other].size(), 2, "Encoded again for other values")

		NetworkIdentityServer.deregister_node(subject)
		NetworkIdentityServer.deregister_node(other)
		subject.queue_free()
		other.queue_free()
	)

	test("should write the same with frames reused across peers", func():
		var schema := _NetworkSchema.new()
		var serializer := _SparseSnapshotSerializer.new(schema)

		var subject := await get_subject()
		var other := await get_subject()
		NetworkIdentityServer.register_node(subject)
		NetworkIdentityServer.register_node(other)

		# Peer 2 names the subjects by id, peer 1 by name
		for node in [subject, other]:
			var identifier := NetworkIdentityServer._get_identifier_of(node)
			identifier.set_id_for(2, identifier.get_local_id())

		var snapshot := _Snapshot.of(0, [
			[subject, "position", Vector3.ONE],
			[subject, "scale", Vector3.ONE],
			[other, "position", Vector3.UP],
			[other, "scale", Vector3.ONE]
		], [subject, other])
		var props := _PropertyPool.of([
			[subject, "position"], [subject, "scale"],
			[other, "position"], [other, "scale"]
		])

		var frames := {}
		for peer in [1, 2]:
			var reused := serializer.write_for(peer, snapshot, props, _BaseSnapshotSerializer._default_filter, frames)
			var alone := serializer.write_for(peer, snapshot, props)
			expect_equal(reused, alone)
			expect_equal(serializer.read_from(1, props, to_buffer(reused[0])), snapshot)

		NetworkIdentityServer.deregister_node(subject)
		NetworkIdentityServer.deregister_node(other)
		subject.queue_free()
		other.queue_free()
	)
