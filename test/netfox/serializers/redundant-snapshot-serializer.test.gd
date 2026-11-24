extends SnapshotSerializerTest

func get_suite_name() -> String:
	return "RedundantSnapshotSerializer"

func suite() -> void:
	test("should deserialize to same", func():
		var schema := _NetworkSchema.new()
		var serializer := _RedundantSnapshotSerializer.new(schema)

		var subject := Node3D.new()
		Vest.get_tree().root.add_child.call_deferred(subject)
		await subject.ready
		NetworkIdentityServer.register_node(subject)

		var snapshots := [
			_Snapshot.of(1, [
				[subject, "position", Vector3(1., 0., 0.)],
				[subject, "quaternion", Quaternion.from_euler(Vector3.ZERO)],
				[subject, "scale", Vector3(1., .5, 1.)]
			], [subject]),
			_Snapshot.of(0, [
				[subject, "position", Vector3(0., 0., 0.)],
				[subject, "quaternion", Quaternion.from_euler(Vector3.ONE)],
				[subject, "scale", Vector3(1., 1., 1.)]
			], [subject])
		] as Array[_Snapshot]

		var props := _PropertyPool.of([
			[subject, "position"],
			[subject, "quaternion"],
			[subject, "scale"]
		])

		var serialized := serializer.write_for(1, snapshots, props)
		var deserialized := serializer.read_from(1, props, to_buffer(serialized))

		expect_equal(deserialized.size(), snapshots.size(), "Not all snapshots were deserialized!")
		for i in snapshots.size():
			expect_equal(deserialized[i], snapshots[i])

		Vest.message("Serialized %d snapshots to %d bytes" % [snapshots.size(), serialized.size()])
	)

	test("should deserialize changing and unchanging input", func():
		var subject := await get_registered_subject()
		var props := _PropertyPool.of([[subject, "position"], [subject, "scale"]])
		var snapshots := [
			_Snapshot.of(12, [[subject, "position", Vector3.ONE], [subject, "scale", Vector3.ONE]], [subject]),
			_Snapshot.of(11, [[subject, "position", Vector3.ONE], [subject, "scale", Vector3.ONE]], [subject]),
			_Snapshot.of(10, [[subject, "position", Vector3.UP], [subject, "scale", Vector3.ONE]], [subject]),
			_Snapshot.of(9, [[subject, "position", Vector3.UP], [subject, "scale", Vector3.ONE]], [subject])
		] as Array[_Snapshot]

		var serializer := _RedundantSnapshotSerializer.new(vec3_schema(subject))
		var serialized := serializer.write_for(1, snapshots, props)
		var deserialized := serializer.read_from(1, props, to_buffer(serialized))

		expect_equal(deserialized.size(), snapshots.size())
		for i in snapshots.size():
			expect_equal(deserialized[i], snapshots[i])

		# Tick, count, reference, size and tick codes once, two ticks' values
		expect_equal(serialized.size(), 1 + 1 + reference_size(subject) + 1 + 1 + 2 * 24)

		free_subjects([subject])
	)

	test("should deserialize several subjects", func():
		var subject := await get_registered_subject()
		var other := await get_registered_subject()
		var props := _PropertyPool.of([[subject, "position"], [other, "position"]])
		var schema := vec3_schema(subject)
		schema.add(other, "position", NetworkSchemas.vec3f32())

		var snapshots := [
			_Snapshot.of(5, [[subject, "position", Vector3.ONE], [other, "position", Vector3.UP]], [subject, other]),
			_Snapshot.of(4, [[subject, "position", Vector3.ZERO], [other, "position", Vector3.UP]], [subject, other])
		] as Array[_Snapshot]

		var serializer := _RedundantSnapshotSerializer.new(schema)
		var deserialized := serializer.read_from(1, props, to_buffer(serializer.write_for(1, snapshots, props)))

		expect_equal(deserialized.size(), snapshots.size())
		for i in snapshots.size():
			expect_equal(deserialized[i], snapshots[i])

		free_subjects([subject, other])
	)

	test("should deserialize subject present in some ticks", func():
		var subject := await get_registered_subject()
		var other := await get_registered_subject()
		var props := _PropertyPool.of([[subject, "position"], [other, "position"]])
		var schema := vec3_schema(subject)
		schema.add(other, "position", NetworkSchemas.vec3f32())

		# `other` has no input in the middle tick, and the same before and after
		var snapshots := [
			_Snapshot.of(5, [[subject, "position", Vector3.ONE], [other, "position", Vector3.UP]], [subject, other]),
			_Snapshot.of(4, [[subject, "position", Vector3.ONE]], [subject]),
			_Snapshot.of(3, [[subject, "position", Vector3.ONE], [other, "position", Vector3.UP]], [subject, other])
		] as Array[_Snapshot]

		var serializer := _RedundantSnapshotSerializer.new(schema)
		var deserialized := serializer.read_from(1, props, to_buffer(serializer.write_for(1, snapshots, props)))

		expect_equal(deserialized.size(), snapshots.size())
		for i in snapshots.size():
			expect_equal(deserialized[i], snapshots[i])

		free_subjects([subject, other])
	)

	test("should leave out ticks with no known subject", func():
		var subject := await get_registered_subject()
		var props := _PropertyPool.of([[subject, "position"]])
		var snapshots := [
			_Snapshot.of(5, [[subject, "position", Vector3.ONE]], [subject]),
			_Snapshot.new(4)
		] as Array[_Snapshot]

		var serializer := _RedundantSnapshotSerializer.new(vec3_schema(subject))
		var deserialized := serializer.read_from(1, props, to_buffer(serializer.write_for(1, snapshots, props)))

		expect_equal(deserialized.size(), 1)
		expect_equal(deserialized[0], snapshots[0])

		free_subjects([subject])
	)

	test("should read past unknown subjects", func():
		var writer_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())
		var reader_identity_server := _NetworkIdentityServer.new(TestingCommandServer.new())
		Vest.get_tree().root.add_child.call_deferred(writer_identity_server)
		Vest.get_tree().root.add_child.call_deferred(reader_identity_server)
		await writer_identity_server.ready; await reader_identity_server.ready

		var known_subject := await get_subject()
		var unknown_subject := await get_subject()
		writer_identity_server.register_node(known_subject)
		writer_identity_server.register_node(unknown_subject)
		reader_identity_server.register_node(known_subject)

		var schema := vec3_schema(known_subject)
		schema.add(unknown_subject, "position", NetworkSchemas.vec3f32())
		var writer := _RedundantSnapshotSerializer.new(schema, writer_identity_server)
		var reader := _RedundantSnapshotSerializer.new(schema, reader_identity_server)

		# The unknown subject is written first
		var writer_props := _PropertyPool.of([[unknown_subject, "position"], [known_subject, "position"]])
		var reader_props := _PropertyPool.of([[known_subject, "position"]])
		var snapshots := [
			_Snapshot.of(2, [[unknown_subject, "position", Vector3.ONE], [known_subject, "position", Vector3.UP]], [unknown_subject, known_subject])
		] as Array[_Snapshot]

		var logger := _BaseSnapshotSerializer._logger
		_BaseSnapshotSerializer._logger = RecordingLogger.new()
		var deserialized := reader.read_from(1, reader_props, to_buffer(writer.write_for(1, snapshots, writer_props)))
		_BaseSnapshotSerializer._logger = logger

		expect_equal(deserialized.size(), 1)
		expect_equal(deserialized[0], _Snapshot.of(2, [[known_subject, "position", Vector3.UP]], [known_subject]))

		for identity_server in [writer_identity_server, reader_identity_server]:
			identity_server._command_server.free()
			identity_server.queue_free()
		known_subject.queue_free()
		unknown_subject.queue_free()
	)

	test("should drop truncated packets", func():
		var subject := await get_registered_subject()
		var props := _PropertyPool.of([[subject, "position"], [subject, "scale"]])
		var snapshots := [
			_Snapshot.of(300, [[subject, "position", Vector3.ONE], [subject, "scale", Vector3.ONE]], [subject]),
			_Snapshot.of(299, [[subject, "position", Vector3.UP], [subject, "scale", Vector3.ONE]], [subject])
		] as Array[_Snapshot]

		var serializer := _RedundantSnapshotSerializer.new(vec3_schema(subject))
		var serialized := serializer.write_for(1, snapshots, props)

		var logger := _BaseSnapshotSerializer._logger
		var recording_logger := RecordingLogger.new()
		_BaseSnapshotSerializer._logger = recording_logger

		var read := []
		for size in serialized.size():
			read.append(serializer.read_from(1, props, to_buffer(serialized.slice(0, size))).size())

		_BaseSnapshotSerializer._logger = logger

		var nothing := []
		nothing.resize(serialized.size())
		nothing.fill(0)
		expect_equal(read, nothing)
		# Malformed is every prefix but the empty one and the bare header (a
		# two-byte tick and the count)
		expect_equal(recording_logger.warnings.size(), serialized.size() - 2)

		free_subjects([subject])
	)

	test("should not crash on garbage", func():
		var subject := await get_registered_subject()
		var props := _PropertyPool.of([[subject, "position"], [subject, "scale"]])
		var serializer := _RedundantSnapshotSerializer.new(vec3_schema(subject))
		var local_id := NetworkIdentityServer._get_identifier_of(subject).get_local_id()

		var logger := _BaseSnapshotSerializer._logger
		_BaseSnapshotSerializer._logger = RecordingLogger.new()

		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var read := 0
		for i in 1000:
			var garbage := PackedByteArray()
			garbage.resize(rng.randi_range(1, 64))
			for j in garbage.size():
				garbage[j] = rng.randi_range(0, 255)
			# Name the known subject in every other packet, so its data is read
			if i % 2 == 0 and garbage.size() >= 3:
				garbage[0] = rng.randi_range(0, 127)
				garbage[1] = rng.randi_range(1, 4)
				garbage[2] = local_id
			for snapshot in serializer.read_from(1, props, to_buffer(garbage)):
				read += snapshot.size()

		_BaseSnapshotSerializer._logger = logger
		Vest.message("Read %d properties from garbage" % [read])
		expect(read >= 0)

		free_subjects([subject])
	)

func get_registered_subject() -> Node3D:
	var subject := await get_subject()
	NetworkIdentityServer.register_node(subject)
	return subject

func vec3_schema(subject: Node) -> _NetworkSchema:
	var schema := _NetworkSchema.new()
	schema.add(subject, "position", NetworkSchemas.vec3f32())
	schema.add(subject, "scale", NetworkSchemas.vec3f32())
	return schema

# Size of the reference written for `subject` to peer 1
func reference_size(subject: Node) -> int:
	var buffer := StreamPeerBuffer.new()
	NetworkSchemas._netref().encode(NetworkIdentityServer._get_identifier_of(subject).reference_for(1), buffer)
	return buffer.get_size()

func free_subjects(subjects: Array) -> void:
	for subject in subjects:
		NetworkIdentityServer.deregister_node(subject)
		subject.queue_free()

class RecordingLogger extends NetfoxLogger:
	var warnings := []

	func _init() -> void:
		super("netfox", "Recording")

	func warning(text: String, values: Array = []):
		warnings.append(text % values)

	func debug(text: String, values: Array = []):
		pass
