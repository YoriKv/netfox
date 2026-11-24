extends SnapshotSerializerTest

func get_suite_name() -> String:
	return "TickedSnapshotSerializer"

func suite() -> void:
	test("should read each subject at its own tick, oldest first", func():
		var serializer := _TickedSnapshotSerializer.new(_NetworkSchema.new())
		var subject := await get_subject()
		var other := await get_subject()
		NetworkIdentityServer.register_node(subject)
		NetworkIdentityServer.register_node(other)
		var props := _PropertyPool.of([[subject, "position"], [subject, "scale"], [other, "position"], [other, "scale"]])

		var packets := serializer.write_for(1, 10, [
			[subject, 10, { ^"position": Vector3.ONE }],
			[other, 7, { ^"position": Vector3.UP, ^"scale": Vector3.ONE }]
		], props)
		var snapshots := serializer.read_from(1, props, to_buffer(packets[0]), 64)

		expect_equal(packets.size(), 1, "One packet for several ticks")
		expect_equal(as_values(snapshots), as_values([
			_Snapshot.of(7, [[other, "position", Vector3.UP], [other, "scale", Vector3.ONE]], [other]),
			_Snapshot.of(10, [[subject, "position", Vector3.ONE]], [subject])
		]))

		cleanup([subject, other])
	)

	test("should group subjects of the same tick", func():
		var serializer := _TickedSnapshotSerializer.new(_NetworkSchema.new())
		var subject := await get_subject()
		var other := await get_subject()
		NetworkIdentityServer.register_node(subject)
		NetworkIdentityServer.register_node(other)
		var props := _PropertyPool.of([[subject, "position"], [other, "position"]])

		var packets := serializer.write_for(1, 10, [
			[subject, 8, { ^"position": Vector3.ONE }],
			[other, 8, { ^"position": Vector3.UP }]
		], props)

		expect_equal(as_values(serializer.read_from(1, props, to_buffer(packets[0]), 64)), as_values([
			_Snapshot.of(8, [[subject, "position", Vector3.ONE], [other, "position", Vector3.UP]], [subject, other])
		]))

		cleanup([subject, other])
	)

	test("should share a subject's frame between entries of the same tick and values", func():
		var serializer := _TickedSnapshotSerializer.new(_NetworkSchema.new())
		var subject := await get_subject()
		NetworkIdentityServer.register_node(subject)
		var props := _PropertyPool.of([[subject, "position"]])

		var frames := {}
		var first := serializer.write_for(1, 10, [[subject, 9, { ^"position": Vector3.ONE }]], props, frames)
		var same := serializer.write_for(1, 10, [[subject, 9, { ^"position": Vector3.ONE }]], props, frames)
		serializer.write_for(1, 10, [[subject, 8, { ^"position": Vector3.ONE }]], props, frames)

		expect_equal(first, same)
		expect_equal(frames[subject].size(), 2, "Encoded again for another tick")

		cleanup([subject])
	)

	test("should drop the rest of a packet with a state older than allowed", func():
		var serializer := _TickedSnapshotSerializer.new(_NetworkSchema.new())
		var subject := await get_subject()
		var other := await get_subject()
		NetworkIdentityServer.register_node(subject)
		NetworkIdentityServer.register_node(other)
		var props := _PropertyPool.of([[subject, "position"], [other, "position"]])

		var packets := serializer.write_for(1, 100, [
			[subject, 99, { ^"position": Vector3.ONE }],
			[other, 30, { ^"position": Vector3.UP }],
			[subject, 100, { ^"position": Vector3.UP }]
		], props)

		expect_equal(as_values(serializer.read_from(1, props, to_buffer(packets[0]), 64)), as_values([
			_Snapshot.of(99, [[subject, "position", Vector3.ONE]], [subject])
		]))

		cleanup([subject, other])
	)

	test("should drop the rest of a packet naming properties a subject lacks", func():
		var serializer := _TickedSnapshotSerializer.new(_NetworkSchema.new())
		var subject := await get_subject()
		var other := await get_subject()
		NetworkIdentityServer.register_node(subject)
		NetworkIdentityServer.register_node(other)
		var writer_props := _PropertyPool.of([[subject, "position"], [other, "position"], [other, "scale"]])
		var reader_props := _PropertyPool.of([[subject, "position"], [other, "position"]])

		var packets := serializer.write_for(1, 10, [
			[subject, 10, { ^"position": Vector3.ONE }],
			[other, 10, { ^"scale": Vector3.UP }],
			[subject, 9, { ^"position": Vector3.UP }]
		], writer_props)

		expect_equal(as_values(serializer.read_from(1, reader_props, to_buffer(packets[0]), 64)), as_values([
			_Snapshot.of(10, [[subject, "position", Vector3.ONE]], [subject])
		]))

		cleanup([subject, other])
	)

	test("should read on past unknown identifiers", func():
		var schema := _NetworkSchema.new()
		var writer_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())
		var reader_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())
		Vest.get_tree().root.add_child.call_deferred(writer_identity_server)
		Vest.get_tree().root.add_child.call_deferred(reader_identity_server)
		await writer_identity_server.ready; await reader_identity_server.ready

		var writer := _TickedSnapshotSerializer.new(schema, writer_identity_server)
		var reader := _TickedSnapshotSerializer.new(schema, reader_identity_server)
		var known := await get_subject()
		var unknown := await get_subject()
		writer_identity_server.register_node(known)
		writer_identity_server.register_node(unknown)
		reader_identity_server.register_node(known)

		var packets := writer.write_for(1, 10, [
			[unknown, 10, { ^"position": Vector3.ONE }],
			[known, 9, { ^"position": Vector3.UP }]
		], _PropertyPool.of([[unknown, "position"], [known, "position"]]))

		expect_equal(as_values(reader.read_from(1, _PropertyPool.of([[known, "position"]]), to_buffer(packets[0]), 64)), as_values([
			_Snapshot.of(9, [[known, "position", Vector3.UP]], [known])
		]))

		for identity_server in [writer_identity_server, reader_identity_server]:
			identity_server._command_server.free()
			identity_server.queue_free()
		known.queue_free()
		unknown.queue_free()
	)

# Snapshots as values that compare equal in an array
func as_values(snapshots: Array) -> Array:
	return snapshots.map(func(snapshot: _Snapshot): return [snapshot.tick, snapshot._data, snapshot.get_auth_subjects()])

func cleanup(subjects: Array) -> void:
	for subject in subjects:
		NetworkIdentityServer.deregister_node(subject)
		subject.queue_free()
