extends VestTest

func get_suite_name() -> String:
	return "NetworkSynchronizationServer"

var servers: TestingServers

func before_case(__):
	# Makes sure local peer is 1, otherwise identifiers get random local IDs
	Vest.get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	servers = await TestingServers.create()

	servers.synchronization_server()._rb_enable_input_broadcast = true # Force input broadcast

func after_case(__):
	servers.queue_free()

func suite() -> void:
	define("synchronize_input()", func():
		test("should submit owned", func():
			var owned_node := await get_node()
			var other_node := await get_node()

			other_node.set_multiplayer_authority(2)

			servers.history_server().register_rollback_input(owned_node, "position")
			servers.history_server().register_rollback_input(other_node, "position")

			servers.synchronization_server().register_rollback_input(owned_node, "position")
			servers.synchronization_server().register_rollback_input(other_node, "position")

			servers.history_server()._record_rollback_input(0)
			servers.synchronization_server()._synchronize_input(0)

			skip() # Somehow setup a live client-server connection
		)
	)

	define("synchronize_state()", func():
		test("should submit owned", func():
			skip()
		)

		test("Includes newly authoritative subjects missing from the baseline", func() -> void:
			var host: RefCounted = RefCounted.new()
			var remote_player: RefCounted = RefCounted.new()
			var position: NodePath = NodePath("position")
			var reference: _Snapshot = _Snapshot.new(100)
			reference.set_property(host, position, Vector3.ZERO)
			reference.set_auth(host, true)

			var resimulated: _Snapshot = _Snapshot.new(100)
			resimulated.set_property(host, position, Vector3(1, 0, 0))
			resimulated.set_auth(host, true)
			resimulated.set_property(remote_player, position, Vector3(2, 0, 0))
			resimulated.set_auth(remote_player, true)

			var diff: _Snapshot = _Snapshot.make_patch(reference, resimulated)

			expect_true(diff.has_property(remote_player, position))
			expect_equal(diff.get_property(remote_player, position), Vector3(2, 0, 0))
		)
	)

	define("_make_peer_snapshot()", func():
		test("should include only visible owned auth state for target peer", func():
			var visible_node := await get_node("visible")
			var hidden_node := await get_node("hidden")
			var remote_node := await get_node("remote")
			remote_node.set_multiplayer_authority(2)

			visible_node.position = Vector3.ONE
			hidden_node.position = Vector3.UP
			remote_node.position = Vector3.RIGHT

			servers.synchronization_server().register_rollback_state(visible_node, ^"position")
			servers.synchronization_server().register_rollback_state(hidden_node, ^"position")
			servers.synchronization_server().register_rollback_state(remote_node, ^"position")

			var filter := PeerVisibilityFilter.new()
			filter.default_visibility = false
			filter.set_visibility_for(2, true)
			filter.update_visibility(PackedInt32Array([2, 3]))
			servers.synchronization_server().register_visibility_filter(visible_node, filter)

			var hidden_filter := PeerVisibilityFilter.new()
			hidden_filter.default_visibility = false
			hidden_filter.update_visibility(PackedInt32Array([2, 3]))
			servers.synchronization_server().register_visibility_filter(hidden_node, hidden_filter)

			var snapshot := _Snapshot.of(5, [
				[visible_node, ^"position", visible_node.position],
				[hidden_node, ^"position", hidden_node.position],
				[remote_node, ^"position", remote_node.position]
			], [visible_node, hidden_node, remote_node])

			var peer_snapshot := servers.synchronization_server()._make_peer_snapshot(
				snapshot,
				2,
				servers.synchronization_server()._rb_owned_state_properties
			)

			expect(peer_snapshot.has_property(visible_node, ^"position"))
			expect_equal(peer_snapshot.get_property(visible_node, ^"position"), Vector3.ONE)
			expect(peer_snapshot.is_auth(visible_node))
			expect_not(peer_snapshot.has_subject(hidden_node))
			expect_not(peer_snapshot.has_subject(remote_node))

			visible_node.queue_free()
			hidden_node.queue_free()
			remote_node.queue_free()
		)
	)

	define("rollback sent state history", func():
		test("should remember rollback state separately per peer", func():
			var node := await get_node("subject")
			var snapshot_tick_5 := _Snapshot.of(5, [
				[node, ^"position", Vector3.ONE]
			], [node])
			var snapshot_tick_8 := _Snapshot.of(8, [
				[node, ^"position", Vector3.UP]
			], [node])

			servers.synchronization_server()._remember_sent_rollback_state(2, snapshot_tick_5)
			servers.synchronization_server()._remember_sent_rollback_state(3, snapshot_tick_8)

			var peer_2_latest := servers.synchronization_server()._get_last_sent_rollback_state(2, 8)
			var peer_3_latest := servers.synchronization_server()._get_last_sent_rollback_state(3, 8)

			expect_not_null(peer_2_latest)
			expect_not_null(peer_3_latest)
			expect_equal(peer_2_latest.tick, 5)
			expect_equal(peer_2_latest.get_property(node, ^"position"), Vector3.ONE)
			expect_equal(peer_3_latest.tick, 8)
			expect_equal(peer_3_latest.get_property(node, ^"position"), Vector3.UP)
			expect_null(servers.synchronization_server()._get_last_sent_rollback_state(4, 8))

			node.queue_free()
		)

		test("should duplicate remembered rollback state", func():
			var node := await get_node("subject")
			var snapshot := _Snapshot.of(5, [
				[node, ^"position", Vector3.ONE]
			], [node])

			servers.synchronization_server()._remember_sent_rollback_state(2, snapshot)
			snapshot.set_property(node, ^"position", Vector3.ZERO)

			var remembered := servers.synchronization_server()._get_last_sent_rollback_state(2, 5)
			expect_not_null(remembered)
			expect_equal(remembered.get_property(node, ^"position"), Vector3.ONE)

			node.queue_free()
		)
	)

	define("reset()", func():
		test("should forget sent states", func():
			var node := await get_node("subject")
			var snapshot := _Snapshot.of(500, [
				[node, ^"position", Vector3.ONE]
			], [node])

			servers.synchronization_server()._remember_sent_rollback_state(2, snapshot)
			servers.synchronization_server()._last_sync_state_sent = snapshot

			servers.synchronization_server().reset()

			expect_null(servers.synchronization_server()._get_last_sent_rollback_state(2, 500))
			expect(servers.synchronization_server()._last_sync_state_sent.is_empty())

			node.queue_free()
		)
	)

	define("get_latest_received_state_tick_for()", func():
		test("should return -1 for unknown", func():
			var node := await get_node()
			expect_equal(servers.synchronization_server().get_latest_received_state_tick_for(node), -1)
		)

		test("should return newest received", func():
			var node := await get_node()
			node.set_multiplayer_authority(2)
			var sync_server := servers.synchronization_server()

			sync_server._ingest_state(2, _Snapshot.of(10, [[node, "position", Vector3.ONE]], [node]))
			sync_server._ingest_state(2, _Snapshot.of(8, [[node, "position", Vector3.ONE]], [node]))
			expect_equal(sync_server.get_latest_received_state_tick_for(node), 10)

			# Unchanged state still counts
			sync_server._ingest_state(2, _Snapshot.of(12, [[node, "position", Vector3.ONE]], [node]))
			expect_equal(sync_server.get_latest_received_state_tick_for(node), 12)

			NetworkHistoryServer.deregister(node)
		)

		test("should ignore non-auth and other senders", func():
			var node := await get_node()
			node.set_multiplayer_authority(2)
			var sync_server := servers.synchronization_server()

			sync_server._ingest_state(2, _Snapshot.of(10, [[node, "position", Vector3.ONE]], []))
			sync_server._ingest_state(3, _Snapshot.of(11, [[node, "position", Vector3.ONE]], [node]))
			expect_equal(sync_server.get_latest_received_state_tick_for(node), -1)

			NetworkHistoryServer.deregister(node)
		)

		test("should forget on deregister and reset", func():
			var node := await get_node()
			node.set_multiplayer_authority(2)
			var sync_server := servers.synchronization_server()

			sync_server._ingest_state(2, _Snapshot.of(10, [[node, "position", Vector3.ONE]], [node]))
			sync_server.deregister(node)
			expect_equal(sync_server.get_latest_received_state_tick_for(node), -1)

			sync_server._ingest_state(2, _Snapshot.of(10, [[node, "position", Vector3.ONE]], [node]))
			sync_server.reset()
			expect_equal(sync_server.get_latest_received_state_tick_for(node), -1)

			NetworkHistoryServer.deregister(node)
		)
	)

	define("inject_rollback_state()", func():
		test("should ingest as received", func():
			var node := await get_node()
			node.set_multiplayer_authority(2)
			var sync_server := servers.synchronization_server()
			var received := []
			sync_server._on_state.connect(func(snapshot: _Snapshot): received.append(snapshot.tick))

			sync_server.inject_rollback_state(node, 6, { ^"position": Vector3.ONE })

			expect_equal(NetworkHistoryServer.get_rollback_state_at(node, 6), { ^"position": Vector3.ONE })
			expect_equal(received, [6])
			expect_equal(sync_server.get_latest_received_state_tick_for(node), 6)
			NetworkHistoryServer.deregister(node)
		)
	)

	define("inject_rollback_input()", func():
		test("should ingest as received", func():
			var node := await get_node()
			node.set_multiplayer_authority(2)
			var sync_server := servers.synchronization_server()
			var received := []
			sync_server._on_input.connect(func(snapshot: _Snapshot): received.append(snapshot.tick))

			sync_server.inject_rollback_input(node, 6, { ^"position": Vector3.ONE })

			expect_equal(NetworkHistoryServer.get_rollback_input_at(node, 6), { ^"position": Vector3.ONE })
			expect_equal(received, [6])
			NetworkHistoryServer.deregister(node)
		)
	)

	define("synchronize_sync_state()", func():
		test("should submit owned", func():
			skip()
		)
	)

func get_node(name: String = "") -> Node3D:
	var node := Node3D.new()

	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready
	if name: node.name = name

	return node
