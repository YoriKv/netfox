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
	NetworkSynchronizationServer._input_max_late = -1
	NetworkSynchronizationServer._input_max_early = 4
	NetworkTimeSynchronizer._clock.offset = 0.
	NetworkMocks.set_tick(0, 0)
	NetworkHistoryServer.reset()
	NetworkRollback.reset()

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

		test("should send nothing for a tick without auth state", func():
			var sync_server := await get_peered_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			set_rollback_state(1, node, Vector3.ONE, true)
			set_rollback_state(2, node, Vector3.UP, false)
			sync_server._synchronize_state(1)
			sync_server._synchronize_state(2)

			expect_equal(sent_state_ticks(sync_server, 2), [[1, true]])

			cleanup(sync_server, [node])
		)

		test("should send peers seeing the same the same states", func():
			var sync_server := await get_peered_server([2, 3])
			var node := await get_node("subject")
			var other := await get_node("other")
			register_rollback_state(sync_server, node)
			register_rollback_state(sync_server, other)

			# Peer 3 names the subjects by id, peer 2 by name
			for subject in [node, other]:
				var identifier := servers.identity_server()._get_identifier_of(subject)
				identifier.set_id_for(3, identifier.get_local_id())

			set_rollback_states(1, [[node, Vector3.ZERO], [other, Vector3.ZERO]], [node, other])
			set_rollback_states(2, [[node, Vector3.ONE], [other, Vector3.ZERO]], [node, other])
			set_rollback_states(3, [[node, Vector3.ONE], [other, Vector3.UP]], [node, other])
			set_rollback_states(4, [[node, Vector3.ONE], [other, Vector3.UP]], [node, other])
			for tick in [1, 2, 3, 4, 2]:
				sync_server._synchronize_state(tick)

			var expected := [
				[1, true, as_values(_Snapshot.of(1, [[node, ^"position", Vector3.ZERO], [other, ^"position", Vector3.ZERO]], [node, other]))],
				[2, false, as_values(_Snapshot.of(2, [[node, ^"position", Vector3.ONE]], [node]))],
				[3, false, as_values(_Snapshot.of(3, [[other, ^"position", Vector3.UP]], [other]))]
			]
			expect_equal(sent_states(sync_server, 2, [node, other]), expected)
			expect_equal(sent_states(sync_server, 3, [node, other]), expected)

			cleanup(sync_server, [node, other])
		)

		test("should share what peers sent the same remember", func():
			var sync_server := await get_peered_server([2, 3])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			# Each peer was sent the same, remembered apart
			var sent := _Snapshot.of(1, [[node, ^"position", Vector3.ZERO]], [node])
			sync_server._remember_sent_rollback_state(2, sent)
			sync_server._remember_sent_rollback_state(3, sent)

			set_rollback_states(2, [[node, Vector3.ONE]], [node])
			sync_server._synchronize_state(2)

			var remembered := sync_server._get_last_sent_rollback_state(2, 2)
			expect_equal(remembered.get_property(node, ^"position"), Vector3.ONE)
			expect(remembered == sync_server._get_last_sent_rollback_state(3, 2), "Peers should share the remembered state!")

			cleanup(sync_server, [node])
		)

		test("should send peers sent different states their own", func():
			var sync_server := await get_peered_server([2, 3])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			# Peer 3 sees the subject from tick 2 on
			var filter := PeerVisibilityFilter.new()
			filter.set_visibility_for(3, false)
			filter.update_visibility(PackedInt32Array([2, 3]))
			sync_server.register_visibility_filter(node, filter)

			set_rollback_states(1, [[node, Vector3.ZERO]], [node])
			set_rollback_states(2, [[node, Vector3.ONE]], [node])
			set_rollback_states(3, [[node, Vector3.UP]], [node])
			sync_server._synchronize_state(1)
			filter.set_visibility_for(3, true)
			filter.update_visibility(PackedInt32Array([2, 3]))
			sync_server._synchronize_state(2)
			sync_server._synchronize_state(3)

			expect_equal(sent_states(sync_server, 2, [node]), [
				[1, true, as_values(_Snapshot.of(1, [[node, ^"position", Vector3.ZERO]], [node]))],
				[2, false, as_values(_Snapshot.of(2, [[node, ^"position", Vector3.ONE]], [node]))],
				[3, false, as_values(_Snapshot.of(3, [[node, ^"position", Vector3.UP]], [node]))]
			])
			expect_equal(sent_states(sync_server, 3, [node]), [
				[2, true, as_values(_Snapshot.of(2, [[node, ^"position", Vector3.ONE]], [node]))],
				[3, false, as_values(_Snapshot.of(3, [[node, ^"position", Vector3.UP]], [node]))]
			])

			filter.free()
			cleanup(sync_server, [node])
		)

		test("should keep full state interval over ticks without auth state", func():
			var sync_server := await get_peered_server([2])
			sync_server._rb_full_scheduler = _IntervalScheduler.new(2)
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			set_rollback_state(1, node, Vector3.ONE, true)
			set_rollback_state(2, node, Vector3.UP, false)
			set_rollback_state(3, node, Vector3.UP, true)
			for tick in [1, 2, 3]:
				sync_server._synchronize_state(tick)

			# Tick 1 is full as the first sent, tick 2 takes the full slot
			expect_equal(sent_state_ticks(sync_server, 2), [[1, true], [3, false]])

			cleanup(sync_server, [node])
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

	define("newest state only", func():
		test("should send each subject's newest authoritative state once per loop", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			for tick in range(1, 6):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) })
			newest_loop(sync_server, 5)
			# A burst: three ticks authoritative in one loop, then two recorded without input
			for tick in range(6, 9):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) })
			for tick in range(9, 11):
				record_state(tick, node, { ^"position": Vector3(8, 0, 0) }, false)
			newest_loop(sync_server, 10)

			expect_equal(sent_newest(sync_server, 2, [node]), [
				[[5, 0, { ^"position": Vector3(5, 0, 0) }]],
				[[8, 0, { ^"position": Vector3(8, 0, 0) }]]
			])

			cleanup(sync_server, [node])
		)

		test("should send nothing from the per-tick synchronization", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			set_rollback_state(1, node, Vector3.ONE, true)
			sync_server._synchronize_state(1)

			expect_empty(sent_state_ticks(sync_server, 2))

			cleanup(sync_server, [node])
		)

		test("should send subjects of different newest ticks in one packet", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			var other := await get_node("other")
			register_rollback_state(sync_server, node)
			register_rollback_state(sync_server, other)

			for tick in range(1, 8):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) })
				record_state(tick, other, { ^"position": Vector3(0, tick, 0) }, tick <= 5)
			newest_loop(sync_server, 7)

			expect_equal(sent_newest(sync_server, 2, [node, other]), [[
				[5, 1, { ^"position": Vector3(0, 5, 0) }],
				[7, 0, { ^"position": Vector3(7, 0, 0) }]
			]])

			cleanup(sync_server, [node, other])
		)

		test("should send what changed since the state last sent", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)
			sync_server.register_rollback_state(node, ^"scale")

			record_state(1, node, { ^"position": Vector3.ZERO, ^"scale": Vector3.ONE })
			newest_loop(sync_server, 1)
			# Changed and changed back between the two newest: not part of the diff
			record_state(2, node, { ^"position": Vector3.UP, ^"scale": Vector3.ONE * 2 })
			record_state(3, node, { ^"position": Vector3.UP, ^"scale": Vector3.ONE })
			newest_loop(sync_server, 3)
			# Unchanged since sent, if newer
			record_state(4, node, { ^"position": Vector3.UP, ^"scale": Vector3.ONE })
			newest_loop(sync_server, 4)

			expect_equal(sent_newest(sync_server, 2, [node], [^"position", ^"scale"]), [
				[[1, 0, { ^"position": Vector3.ZERO, ^"scale": Vector3.ONE }]],
				[[3, 0, { ^"position": Vector3.UP }]]
			])
			expect_equal(sync_server._rb_newest_sent[2][node].tick, 3, "The diff reference stays the state sent")

			cleanup(sync_server, [node])
		)

		test("should send the newest state again when a late input changed it", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			for tick in range(1, 6):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) })
			newest_loop(sync_server, 5)
			# A late input of another node changes an older tick only, then the newest
			record_state(3, node, { ^"position": Vector3.UP })
			newest_loop(sync_server, 6)
			record_state(5, node, { ^"position": Vector3.UP })
			newest_loop(sync_server, 7)

			expect_equal(sent_newest(sync_server, 2, [node]), [
				[[5, 0, { ^"position": Vector3(5, 0, 0) }]],
				[[5, 0, { ^"position": Vector3.UP }]]
			])

			cleanup(sync_server, [node])
		)

		test("should send an older newest state once states lost authority", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			for tick in range(1, 9):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) })
			newest_loop(sync_server, 8)
			# Starvation fills from 6 on withdrawn, tick 6 simulated again with real input
			for tick in range(6, 10):
				record_state(tick, node, { ^"position": Vector3.UP }, tick == 6)
			newest_loop(sync_server, 9)

			expect_equal(sent_newest(sync_server, 2, [node]), [
				[[8, 0, { ^"position": Vector3(8, 0, 0) }]],
				[[6, 0, { ^"position": Vector3.UP }]]
			])

			cleanup(sync_server, [node])
		)

		test("should send a subject in full once visible, and on full states", func():
			var sync_server := await get_newest_server([2])
			sync_server._rb_full_scheduler = _IntervalScheduler.new(4)
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)
			sync_server.register_rollback_state(node, ^"scale")
			var filter := PeerVisibilityFilter.new()
			filter.default_visibility = false
			filter.update_visibility(PackedInt32Array([2]))
			sync_server.register_visibility_filter(node, filter)

			for tick in range(1, 12):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0), ^"scale": Vector3.ONE })
			newest_loop(sync_server, 1)
			filter.default_visibility = true
			filter.update_visibility(PackedInt32Array([2]))
			newest_loop(sync_server, 2)
			newest_loop(sync_server, 3)
			# Hidden, then visible again
			filter.default_visibility = false
			filter.update_visibility(PackedInt32Array([2]))
			newest_loop(sync_server, 4)
			filter.default_visibility = true
			filter.update_visibility(PackedInt32Array([2]))
			newest_loop(sync_server, 6)
			# The 4th tick counted since is a full state's, in a loop of two new ticks
			newest_loop(sync_server, 7)
			newest_loop(sync_server, 9)

			expect_equal(sent_newest(sync_server, 2, [node], [^"position", ^"scale"]), [
				[[2, 0, { ^"position": Vector3(2, 0, 0), ^"scale": Vector3.ONE }]],
				[[3, 0, { ^"position": Vector3(3, 0, 0) }]],
				[[6, 0, { ^"position": Vector3(6, 0, 0), ^"scale": Vector3.ONE }]],
				[[7, 0, { ^"position": Vector3(7, 0, 0) }]],
				[[9, 0, { ^"position": Vector3(9, 0, 0), ^"scale": Vector3.ONE }]]
			])

			filter.free()
			cleanup(sync_server, [node])
		)

		test("should send no full state of a subject without a newer state", func():
			var sync_server := await get_newest_server([2])
			sync_server._rb_full_scheduler = _IntervalScheduler.new(2)
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			# Its owner fell silent after tick 2
			for tick in range(1, 7):
				record_state(tick, node, { ^"position": Vector3.ONE }, tick <= 2)
			for to in range(1, 7):
				newest_loop(sync_server, to)

			expect_equal(sent_newest(sync_server, 2, [node]), [
				[[1, 0, { ^"position": Vector3.ONE }]],
				[[2, 0, { ^"position": Vector3.ONE }]]
			], "The full state at 2, none at 4 and 6")

			cleanup(sync_server, [node])
		)

		test("should send owner-only properties to the input owner only", func():
			var sync_server := await get_newest_server([2, 3])
			var node := await get_node("subject")
			var input := await get_node("input")
			input.set_multiplayer_authority(2)
			servers.simulation_server().register_rollback_input_for(node, input)
			register_owner_state(sync_server, node)

			record_state(1, node, { ^"position": Vector3.ZERO, ^"scale": Vector3.ONE })
			newest_loop(sync_server, 1)
			record_state(2, node, { ^"position": Vector3.ZERO, ^"scale": Vector3.ONE * 2 })
			newest_loop(sync_server, 2)
			input.set_multiplayer_authority(3)
			record_state(3, node, { ^"position": Vector3.UP, ^"scale": Vector3.ONE * 2 })
			newest_loop(sync_server, 3)

			var properties: Array[NodePath] = [^"position", ^"scale"]
			expect_equal(sent_newest(sync_server, 2, [node], properties), [
				[[1, 0, { ^"position": Vector3.ZERO, ^"scale": Vector3.ONE }]],
				[[2, 0, { ^"scale": Vector3.ONE * 2 }]],
				[[3, 0, { ^"position": Vector3.UP }]]
			])
			expect_equal(sent_newest(sync_server, 3, [node], properties), [
				[[1, 0, { ^"position": Vector3.ZERO }]],
				[[3, 0, { ^"position": Vector3.UP, ^"scale": Vector3.ONE * 2 }]]
			], "Nothing while only owner-only properties change; all of them once it owns the input")

			servers.simulation_server().deregister_node(node)
			input.queue_free()
			cleanup(sync_server, [node])
		)

		test("should share what peers sent the same were sent", func():
			var sync_server := await get_newest_server([2, 3, 4])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)
			var filter := PeerVisibilityFilter.new()
			filter.set_visibility_for(4, false)
			filter.update_visibility(PackedInt32Array([2, 3, 4]))
			sync_server.register_visibility_filter(node, filter)

			record_state(1, node, { ^"position": Vector3.ZERO })
			newest_loop(sync_server, 1)
			filter.set_visibility_for(4, true)
			filter.update_visibility(PackedInt32Array([2, 3, 4]))
			record_state(2, node, { ^"position": Vector3.ONE })
			newest_loop(sync_server, 2)

			var sent := sync_server._rb_newest_sent as Dictionary
			expect(sent[2][node] == sent[3][node], "Peers sent the same share the record")
			expect(sent[4][node] != sent[2][node], "A peer sent a full state has its own")
			expect_equal(sent_newest(sync_server, 4, [node]), [[[2, 0, { ^"position": Vector3.ONE }]]])

			filter.free()
			cleanup(sync_server, [node])
		)

		test("should send the others each state since the one last sent, with the setting", func():
			var sync_server := await get_newest_server([2, 3])
			sync_server._rb_send_intermediate = true
			var node := await get_node("subject")
			var input := await get_node("input")
			input.set_multiplayer_authority(2)
			servers.simulation_server().register_rollback_input_for(node, input)
			register_rollback_state(sync_server, node)

			for tick in range(1, 4):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) })
			newest_loop(sync_server, 3)
			for tick in range(4, 7):
				record_state(tick, node, { ^"position": Vector3(tick, 0, 0) if tick != 5 else Vector3(4, 0, 0) })
			record_state(7, node, { ^"position": Vector3(6, 0, 0) }, false)
			newest_loop(sync_server, 7)

			expect_equal(sent_newest(sync_server, 2, [node]), [
				[[3, 0, { ^"position": Vector3(3, 0, 0) }]],
				[[6, 0, { ^"position": Vector3(6, 0, 0) }]]
			], "The input owner gets the newest only")
			expect_equal(sent_newest(sync_server, 3, [node]), [
				[[3, 0, { ^"position": Vector3(3, 0, 0) }]],
				[[4, 0, { ^"position": Vector3(4, 0, 0) }], [6, 0, { ^"position": Vector3(6, 0, 0) }]]
			], "Others each changed state since, in one packet")

			servers.simulation_server().deregister_node(node)
			input.queue_free()
			cleanup(sync_server, [node])
		)

		test("should ingest each subject's state at its own tick", func():
			var receiver := NetworkSynchronizationServer
			var node := await get_node("subject")
			var other := await get_node("other")
			var properties := _PropertyPool.new()
			for subject in [node, other]:
				NetworkIdentityServer.register_node(subject)
				receiver.register_rollback_state(subject, ^"position")
				NetworkHistoryServer.register_rollback_state(subject, ^"position")
				properties.add(subject, ^"position")
			set_clock_tick(10)
			var data := _TickedSnapshotSerializer.new(_NetworkSchema.new()).write_for(1, 10, [
				[node, 9, { ^"position": Vector3.ONE }], [other, 7, { ^"position": Vector3.UP }]
			], properties)[0]

			receiver._handle_newest_state(1, data)

			expect_equal(NetworkHistoryServer.get_rollback_state_at(node, 9), { ^"position": Vector3.ONE })
			expect_equal(NetworkHistoryServer.get_rollback_state_at(other, 7), { ^"position": Vector3.UP })
			expect_equal([receiver.get_latest_received_state_tick_for(node), receiver.get_latest_received_state_tick_for(other)], [9, 7])

			for subject in [node, other]:
				receiver.deregister(subject)
				NetworkIdentityServer.deregister_node(subject)
			cleanup_global([node, other])
		)

		test("should send nothing for a subject without authoritative state", func():
			var sync_server := await get_newest_server([2])
			var node := await get_node("subject")
			register_rollback_state(sync_server, node)

			for tick in range(1, 4):
				record_state(tick, node, { ^"position": Vector3.ONE }, false)
			newest_loop(sync_server, 3)

			expect_empty(sent_newest(sync_server, 2, [node]))

			cleanup(sync_server, [node])
		)
	)

	define("owner-only state", func():
		test("should send owner-only properties to the input owner only", func():
			var sync_server := await get_peered_server([2, 3])
			sync_server._rb_full_scheduler = _IntervalScheduler.new(0)
			var node := await get_node("subject")
			var input := await get_node("input")
			input.set_multiplayer_authority(2)
			servers.simulation_server().register_rollback_input_for(node, input)
			register_owner_state(sync_server, node)

			set_owner_states(1, node, Vector3.ZERO, Vector3.ONE)
			set_owner_states(2, node, Vector3.UP, Vector3.ONE * 2)
			sync_server._synchronize_state(1)
			sync_server._synchronize_state(2)

			expect_equal(sent_owner_states(sync_server, 2, node), [
				[1, true, { ^"position": Vector3.ZERO, ^"scale": Vector3.ONE }],
				[2, false, { ^"position": Vector3.UP, ^"scale": Vector3.ONE * 2 }]
			])
			expect_equal(sent_owner_states(sync_server, 3, node), [
				[1, true, { ^"position": Vector3.ZERO }],
				[2, false, { ^"position": Vector3.UP }]
			])

			servers.simulation_server().deregister_node(node)
			input.queue_free()
			cleanup(sync_server, [node])
		)

		test("should send nothing to others when only owner-only properties change", func():
			var sync_server := await get_peered_server([2, 3])
			sync_server._rb_full_scheduler = _IntervalScheduler.new(0)
			var node := await get_node("subject")
			var input := await get_node("input")
			input.set_multiplayer_authority(2)
			servers.simulation_server().register_rollback_input_for(node, input)
			register_owner_state(sync_server, node)

			set_owner_states(1, node, Vector3.ZERO, Vector3.ONE)
			set_owner_states(2, node, Vector3.ZERO, Vector3.ONE * 2)
			sync_server._synchronize_state(1)
			sync_server._synchronize_state(2)

			expect_equal(sent_state_ticks(sync_server, 2), [[1, true], [2, false]])
			expect_equal(sent_state_ticks(sync_server, 3), [[1, true]])

			servers.simulation_server().deregister_node(node)
			input.queue_free()
			cleanup(sync_server, [node])
		)

		test("should send owner-only properties to a new input owner", func():
			var sync_server := await get_peered_server([2, 3])
			sync_server._rb_full_scheduler = _IntervalScheduler.new(0)
			var node := await get_node("subject")
			var input := await get_node("input")
			input.set_multiplayer_authority(2)
			servers.simulation_server().register_rollback_input_for(node, input)
			register_owner_state(sync_server, node)

			set_owner_states(1, node, Vector3.ZERO, Vector3.ONE)
			set_owner_states(2, node, Vector3.ZERO, Vector3.ONE)
			sync_server._synchronize_state(1)
			input.set_multiplayer_authority(3)
			sync_server._synchronize_state(2)

			expect_equal(sent_owner_states(sync_server, 3, node), [
				[1, true, { ^"position": Vector3.ZERO }],
				[2, false, { ^"scale": Vector3.ONE }]
			])

			servers.simulation_server().deregister_node(node)
			input.queue_free()
			cleanup(sync_server, [node])
		)

		test("should read a full state without the owner-only properties of others' nodes", func():
			var node := await get_node("subject")
			var input := await get_node("input")
			node.set_multiplayer_authority(2)
			input.set_multiplayer_authority(3)
			RollbackSimulationServer.register_rollback_input_for(node, input)
			var sync_server := servers.synchronization_server()
			servers.identity_server().register_node(node)
			sync_server.register_rollback_state(node, ^"position")
			sync_server.register_rollback_state(node, ^"scale", true)

			var properties := _PropertyPool.of([[node, ^"position"]])
			var dense := _DenseSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())
			var buffer := StreamPeerBuffer.new()
			buffer.put_u32(7)
			NetworkSchemas._netref().encode(servers.identity_server()._get_identifier_of(node).reference_for(1), buffer)
			var values := StreamPeerBuffer.new()
			_NetworkSchema.new().encode(node, ^"position", Vector3.UP, values)
			NetworkSchemas.varuint().encode(values.get_size(), buffer)
			buffer.put_data(values.data_array)
			buffer.seek(0)

			var snapshot := dense.read_from(2, sync_server._rb_state_properties, buffer, true, sync_server._get_state_property_filter(1))

			expect_equal(snapshot._data, { node: { ^"position": Vector3.UP } })

			RollbackSimulationServer.deregister_node(node)
			input.queue_free()
			sync_server.deregister(node)
			node.queue_free()
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

	define("input acceptance", func():
		test("should refuse input too far ahead, keeping the input of others", func():
			var sync_server := NetworkSynchronizationServer
			set_clock_tick(100)
			var own := await get_node("own")
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(own, ^"position")
			NetworkHistoryServer.register_rollback_input(remote, ^"position")
			for tick in range(90, 101):
				NetworkHistoryServer._record_rollback_input(tick)
			var refusals := record_refusals()
			var refused_before := NetworkPerformance.get_inputs_refused_by(2)

			sync_server._ingest_input(2, _Snapshot.of(1100, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_equal(refusals, [[2, 1100]])
			expect_equal(NetworkPerformance.get_inputs_refused_by(2) - refused_before, 1)
			expect(NetworkHistoryServer._get_rollback_input_snapshot(99).has_subject(own, true), "Input of others should be kept!")
			expect_empty(NetworkHistoryServer.get_rollback_input_at(remote, 1100))

			sync_server.on_input_refused.disconnect(_refusal_handler)
			cleanup_global([own, remote])
		)

		test("should accept input up to the early bound and input delay", func():
			var sync_server := NetworkSynchronizationServer
			set_clock_tick(100)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(remote, ^"position")
			var latest := 100 + NetworkRollback.input_delay + sync_server._input_max_early

			sync_server._ingest_input(2, _Snapshot.of(latest, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_equal(sync_server.get_latest_input_tick(), latest)
			expect_equal(NetworkHistoryServer.get_rollback_input_at(remote, latest), { ^"position": Vector3.ONE })
			cleanup_global([remote])
		)

		test("should measure early input from the reference clock while behind it", func():
			var sync_server := NetworkSynchronizationServer
			set_clock_tick(130)
			NetworkMocks.set_network_tick(100)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(remote, ^"position")

			sync_server._ingest_input(2, _Snapshot.of(131, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_equal(NetworkHistoryServer.get_rollback_input_at(remote, 131), { ^"position": Vector3.ONE })
			cleanup_global([remote])
		)

		test("should refuse a state too far ahead", func():
			var sync_server := NetworkSynchronizationServer
			set_clock_tick(100)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_state(remote, ^"position")
			for tick in range(90, 101):
				NetworkHistoryServer._record_rollback_state(tick)

			sync_server._ingest_state(2, _Snapshot.of(1100, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_not_null(NetworkHistoryServer._get_rollback_state_snapshot(99))
			expect_equal(NetworkHistoryServer.get_latest_state_tick_for([remote], 99), 99)
			expect_equal(sync_server.get_latest_received_state_tick_for(remote), -1)
			cleanup_global([remote])
		)

		test("should refuse input later than the window, without resimulating", func():
			var sync_server := NetworkSynchronizationServer
			sync_server._input_max_late = 15
			set_clock_tick(100)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(remote, ^"position")
			var refusals := record_refusals()

			sync_server._ingest_input(2, _Snapshot.of(84, [[remote, ^"position", Vector3.ONE]], [remote]))
			sync_server._ingest_input(2, _Snapshot.of(85, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_equal(refusals, [[2, 84]])
			expect_empty(NetworkHistoryServer.get_rollback_input_at(remote, 84))
			expect_equal(NetworkRollback._earliest_input, 85)

			sync_server.on_input_refused.disconnect(_refusal_handler)
			cleanup_global([remote])
		)

		test("should drop late copies of known input quietly", func():
			var sync_server := NetworkSynchronizationServer
			sync_server._input_max_late = 15
			set_clock_tick(80)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(remote, ^"position")
			sync_server._ingest_input(2, _Snapshot.of(80, [[remote, ^"position", Vector3.ONE]], [remote]))
			var refusals := record_refusals()

			set_clock_tick(100)
			sync_server._ingest_input(2, _Snapshot.of(80, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_empty(refusals)

			sync_server.on_input_refused.disconnect(_refusal_handler)
			cleanup_global([remote])
		)

		test("should accept input as late as the history by default", func():
			var sync_server := NetworkSynchronizationServer
			set_clock_tick(100)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(remote, ^"position")

			sync_server._ingest_input(2, _Snapshot.of(NetworkRollback.history_start, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_equal(sync_server.get_earliest_input_tick(), 100 - NetworkRollback.history_limit)
			expect_equal(NetworkHistoryServer.get_rollback_input_at(remote, NetworkRollback.history_start), { ^"position": Vector3.ONE })
			cleanup_global([remote])
		)

		test("should leave input from before a stall to the history", func():
			var sync_server := NetworkSynchronizationServer
			set_clock_tick(120)
			NetworkRollback._handle_tick_jump(120)
			var remote := await get_node("remote")
			remote.set_multiplayer_authority(2)
			NetworkHistoryServer.register_rollback_input(remote, ^"position")
			var refusals := record_refusals()

			sync_server._ingest_input(2, _Snapshot.of(110, [[remote, ^"position", Vector3.ONE]], [remote]))

			expect_empty(refusals)
			expect_empty(NetworkHistoryServer.get_rollback_input_at(remote, 110))

			sync_server.on_input_refused.disconnect(_refusal_handler)
			cleanup_global([remote])
		)
	)

	define("input starvation", func():
		test("should fill a silence once, then each new tick", func():
			var sync_server := await get_peered_server([2])
			var setup := await starving_input(sync_server, 10)
			var input := setup[0] as StarvingInput
			ingest_inputs(sync_server, input, range(70, 81), 100)
			var rewinds := record_inputs(sync_server)

			NetworkMocks.set_network_tick(90)
			sync_server._starve_inputs()
			expect_empty(fills_of(sync_server, input), "Not silent while the newest input is the threshold old")

			NetworkMocks.set_network_tick(92)
			sync_server._starve_inputs()
			expect_equal(fills_of(sync_server, input), range(81, 92), "One fill from the newest input up to the loop's tick")
			expect_equal(rewinds.min(), 81, "One rewind, as deep as the threshold")
			expect_equal(input.starved, range(81, 92))
			expect_equal(NetworkHistoryServer.get_rollback_input_at(input, 85), { ^"position": Vector3(80, 0, 0) })

			rewinds.clear()
			NetworkMocks.set_network_tick(93)
			sync_server._starve_inputs()
			expect_equal(rewinds, [92], "Then only the new tick, the newest the loop simulates")
			NetworkMocks.set_network_tick(95)
			sync_server._starve_inputs()
			expect_equal(rewinds, [92, 93, 94])

			cleanup_starving(sync_server, setup)
		)

		test("should fill a lost tick with a copy once input redundancy ticks later arrived", func():
			var sync_server := await get_peered_server([2])
			var setup := await starving_input(sync_server, 10)
			var input := setup[0] as StarvingInput
			NetworkMocks.set_network_tick(90)
			ingest_inputs(sync_server, input, [80, 81, 83], 100)

			for tick in range(84, 82 + NetworkRollback.input_redundancy):
				ingest_inputs(sync_server, input, [tick], 100)
			sync_server._starve_inputs()
			expect_empty(fills_of(sync_server, input), "The lost tick may still arrive")

			ingest_inputs(sync_server, input, [82 + NetworkRollback.input_redundancy], 100)
			var rewinds := record_inputs(sync_server)
			sync_server._starve_inputs()
			expect_equal(fills_of(sync_server, input), [82])
			expect_equal(rewinds, [82], "A rewind as deep as the lateness and the redundancy")
			expect_empty(input.starved, "A gap is a copy, no hook")
			expect_equal(NetworkHistoryServer.get_rollback_input_at(input, 82), { ^"position": Vector3(81, 100, 0) })

			# A late copy of it changes nothing
			var refusals := record_server_refusals(sync_server)
			sync_server._ingest_input(2, _Snapshot.of(82, [[input, ^"position", Vector3.ONE]], [input]))
			expect_equal(NetworkHistoryServer.get_rollback_input_at(input, 82), { ^"position": Vector3(81, 100, 0) })
			expect_empty(refusals)

			cleanup_starving(sync_server, setup)
		)

		test("should withdraw fills from the input ending a silence and refuse older input", func():
			var sync_server := await get_peered_server([2])
			var setup := await starving_input(sync_server, 10)
			var input := setup[0] as StarvingInput
			ingest_inputs(sync_server, input, range(70, 81), 100)
			NetworkMocks.set_network_tick(92)
			sync_server._starve_inputs()
			var refusals := record_server_refusals(sync_server)

			# A delayed input from before the silence
			sync_server._ingest_input(2, _Snapshot.of(80, [[input, ^"position", Vector3.ONE]], [input]))
			NetworkMocks.set_network_tick(94)
			sync_server._ingest_input(2, _Snapshot.of(89, [[input, ^"position", Vector3.ONE]], [input]))
			# Real input for a tick the silence filled
			sync_server._ingest_input(2, _Snapshot.of(88, [[input, ^"position", Vector3.ONE]], [input]))

			expect_equal(refusals, [[2, 80], [2, 88]])
			expect_equal(NetworkHistoryServer.get_rollback_input_at(input, 88), { ^"position": Vector3(80, 0, 0) })
			expect_equal(NetworkHistoryServer.get_rollback_input_at(input, 89), { ^"position": Vector3.ONE })
			expect_empty(NetworkHistoryServer.get_rollback_input_at(input, 90), "Fills after it are withdrawn")
			expect_not(NetworkHistoryServer._get_rollback_input_snapshot(90).has_subject(input))
			expect_equal(NetworkHistoryServer.get_latest_input_for([input], 94), 89)
			expect_not(sync_server._starved_from.has(input))
			expect_equal(fills_of(sync_server, input), range(81, 89))

			cleanup_starving(sync_server, setup)
		)

		test("should not fill before the first input, for a dead node or an owner gone", func():
			var sync_server := await get_peered_server([2])
			var setup := await starving_input(sync_server, 10)
			var input := setup[0] as StarvingInput

			NetworkMocks.set_network_tick(92)
			sync_server._starve_inputs()
			expect_empty(fills_of(sync_server, input), "Before the first input")

			ingest_inputs(sync_server, input, [80], 100)
			sync_server.peers = PackedInt32Array([3])
			sync_server._starve_inputs()
			expect_empty(fills_of(sync_server, input), "The owner gone")

			sync_server.peers = PackedInt32Array([2])
			# A state node beside it without liveness, as a child holding state
			var state_node := await get_node("state")
			servers.simulation_server().register_rollback_input_for(state_node, input)
			RollbackLivenessServer.register(setup[1], func(): pass, func(): pass, func(): pass, 0)
			RollbackLivenessServer.despawn(setup[1], 85)
			sync_server._starve_inputs()
			expect_empty(fills_of(sync_server, input), "Despawned")

			RollbackLivenessServer.deregister(setup[1])
			servers.simulation_server().deregister_node(state_node)
			state_node.queue_free()
			cleanup_starving(sync_server, setup)
		)
	)

	define("synchronize_sync_state()", func():
		test("should submit owned", func():
			skip()
		)

		test("should send nothing when nothing changed", func():
			var sync_server := await get_peered_server([2])
			var node := await get_node("subject")
			register_sync_state(sync_server, node)

			sync_tick(sync_server, node, 1, Vector3.ONE)
			var first := sent_diffs(sync_server, 2)
			sync_tick(sync_server, node, 2, Vector3.ONE)

			expect_equal(first.size(), 1)
			expect_empty(sent_diffs(sync_server, 2).slice(first.size()))

			cleanup(sync_server, [node])
		)

		test("should send only changed subjects", func():
			var sync_server := await get_peered_server([2])
			var moving := await get_node("moving")
			var resting := await get_node("resting")
			register_sync_state(sync_server, moving)
			register_sync_state(sync_server, resting)

			moving.position = Vector3.ZERO
			resting.position = Vector3.ONE
			sync_tick(sync_server, null, 1)
			moving.position = Vector3.UP
			sync_tick(sync_server, null, 2)

			var diffs := sent_diffs(sync_server, 2)
			var last := decode_diff(sync_server, diffs[-1], [moving, resting])
			expect_equal(last, _Snapshot.of(2, [[moving, ^"position", Vector3.UP]], [moving]))

			cleanup(sync_server, [moving, resting])
		)

		test("should send subject in full once visible", func():
			var sync_server := await get_peered_server([2])
			var node := await get_node("subject")
			register_sync_state(sync_server, node)

			var filter := PeerVisibilityFilter.new()
			filter.default_visibility = false
			filter.update_visibility(PackedInt32Array([2]))
			sync_server.register_visibility_filter(node, filter)

			sync_tick(sync_server, node, 1, Vector3.ONE)
			sync_tick(sync_server, node, 2, Vector3.ONE)
			expect_empty(sent_diffs(sync_server, 2))

			# Visible from now on, unchanged
			filter.default_visibility = true
			filter.update_visibility(PackedInt32Array([2]))
			sync_tick(sync_server, node, 3, Vector3.ONE)
			sync_tick(sync_server, node, 4, Vector3.ONE)

			var diffs := sent_diffs(sync_server, 2)
			expect_equal(diffs.size(), 1)
			expect_equal(decode_diff(sync_server, diffs[0], [node]),
				_Snapshot.of(3, [[node, ^"position", Vector3.ONE]], [node]))

			# Hidden, then visible again, still unchanged
			filter.default_visibility = false
			filter.update_visibility(PackedInt32Array([2]))
			sync_tick(sync_server, node, 5, Vector3.ONE)
			filter.default_visibility = true
			filter.update_visibility(PackedInt32Array([2]))
			sync_tick(sync_server, node, 6, Vector3.ONE)

			diffs = sent_diffs(sync_server, 2)
			expect_equal(diffs.size(), 2)
			expect_equal(decode_diff(sync_server, diffs[1], [node]),
				_Snapshot.of(6, [[node, ^"position", Vector3.ONE]], [node]))

			filter.free()
			cleanup(sync_server, [node])
		)
	)

var _refusal_handler: Callable

# Each input refusal as [peer, tick], until disconnected
func record_refusals() -> Array:
	var result := []
	_refusal_handler = func(peer: int, tick: int): result.append([peer, tick])
	NetworkSynchronizationServer.on_input_refused.connect(_refusal_handler)
	return result

# An input node of peer 2 with starvation, controlling a node of ours
func starving_input(sync_server: _NetworkSynchronizationServer, ticks: int) -> Array:
	var input := StarvingInput.new()
	Vest.get_tree().root.add_child.call_deferred(input)
	await input.ready
	input.set_multiplayer_authority(2)
	var node := await get_node("controlled")
	servers.simulation_server().register_rollback_input_for(node, input)
	NetworkHistoryServer.register_rollback_input(input, ^"position")
	sync_server.register_rollback_input(input, ^"position")
	sync_server.set_input_starvation_for(input, ticks)
	return [input, node]

# Input of peer 2 for each of [param ticks], at (tick, [param y], 0)
func ingest_inputs(sync_server: _NetworkSynchronizationServer, input: Node, ticks: Array, y: float) -> void:
	for tick in ticks:
		sync_server._ingest_input(2, _Snapshot.of(tick, [[input, ^"position", Vector3(tick, y, 0)]], [input]))

# The tick of each input that starts a rewind, until the test ends
func record_inputs(sync_server: _NetworkSynchronizationServer) -> Array:
	var result := []
	sync_server._on_input.connect(func(snapshot: _Snapshot): result.append(snapshot.tick))
	return result

func fills_of(sync_server: _NetworkSynchronizationServer, input: Node) -> Array:
	var ticks := (sync_server._fills.get(input, {}) as Dictionary).keys()
	ticks.sort()
	return ticks

# Each input refusal of [param sync_server] as [peer, tick]
func record_server_refusals(sync_server: _NetworkSynchronizationServer) -> Array:
	var result := []
	sync_server.on_input_refused.connect(func(peer: int, tick: int): result.append([peer, tick]))
	return result

func cleanup_starving(sync_server: Node, setup: Array) -> void:
	servers.simulation_server().deregister_node(setup[1])
	cleanup(sync_server, setup)

class StarvingInput extends Node3D:
	var starved := []

	func _rollback_starve(tick: int) -> void:
		starved.append(tick)
		position.y = 0

# Set both the network tick and the reference clock to [param tick]
func set_clock_tick(tick: int) -> void:
	NetworkMocks.set_network_tick(tick)
	NetworkTimeSynchronizer._clock.set_time((tick + 0.5) * NetworkTime.ticktime)

func cleanup_global(nodes: Array) -> void:
	for node in nodes:
		NetworkHistoryServer.deregister(node)
		node.queue_free()

func get_peered_server(peers: Array) -> PeeredSynchronizationServer:
	var sync_server := PeeredSynchronizationServer.new(servers.command_server(), servers.history_server(), servers.identity_server(), servers.simulation_server())
	sync_server.peers = PackedInt32Array(peers)
	sync_server._sync_full_scheduler = _IntervalScheduler.new(0) # Only diffs
	servers.add_child.call_deferred(sync_server)
	await sync_server.ready
	return sync_server

func get_newest_server(peers: Array) -> PeeredSynchronizationServer:
	var sync_server := PeeredSynchronizationServer.new(servers.command_server(), servers.history_server(), servers.identity_server(), servers.simulation_server())
	sync_server.peers = PackedInt32Array(peers)
	sync_server._rb_send_newest_only = true
	sync_server._rb_full_scheduler = _IntervalScheduler.new(0) # Only diffs
	servers.add_child.call_deferred(sync_server)
	await sync_server.ready
	return sync_server

# Record [param values] of [param node] at [param tick] in the sending history
func record_state(tick: int, node: Node, values: Dictionary, is_auth: bool = true) -> void:
	var record := servers.history_server()._rb_state_history.ensure_snapshot(tick, node, false)
	for property in values:
		record.set_value(property, values[property])
	record.set_auth(is_auth)

# Send the newest states after a rollback loop that recorded up to [param to]
func newest_loop(sync_server: _NetworkSynchronizationServer, to: int) -> void:
	NetworkMocks.set_network_tick(to)
	sync_server._synchronize_newest_state(to)

# Each newest state packet sent to [param peer], as [tick, index in
# [param nodes], values] per subject, oldest first
func sent_newest(sync_server: _NetworkSynchronizationServer, peer: int, nodes: Array, properties: Array[NodePath] = [^"position"]) -> Array:
	var pool := _PropertyPool.new()
	for node in nodes:
		for property in properties:
			pool.add(node, property)
	var serializer := _TickedSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())

	var result := []
	for command in servers.command_server().commands_sent:
		if command[2] != peer or command[0] != sync_server._cmd_newest_state._idx:
			continue
		var buffer := StreamPeerBuffer.new()
		buffer.data_array = command[1]
		var packet := []
		for snapshot in serializer.read_from(1, pool, buffer, 64):
			for subject in snapshot.get_subjects():
				packet.append([snapshot.tick, nodes.find(subject), snapshot._data[subject]])
		result.append(packet)
	return result

func register_sync_state(sync_server: _NetworkSynchronizationServer, node: Node) -> void:
	servers.identity_server().register_node(node)
	sync_server.register_sync_state(node, ^"position")
	NetworkHistoryServer.register_sync_state(node, ^"position")

# Record and send sync state for [param tick], with [param node] at [param position]
func sync_tick(sync_server: _NetworkSynchronizationServer, node: Node3D, tick: int, position: Vector3 = Vector3.ZERO) -> void:
	if node:
		node.position = position
	NetworkHistoryServer._record_sync_state(tick)
	sync_server._synchronize_sync_state(tick)

func register_rollback_state(sync_server: _NetworkSynchronizationServer, node: Node) -> void:
	servers.identity_server().register_node(node)
	sync_server.register_rollback_state(node, ^"position")

func set_rollback_state(tick: int, node: Node, position: Vector3, is_auth: bool) -> void:
	var auth_subjects: Array[Object] = []
	if is_auth:
		auth_subjects.append(node)
	servers.history_server()._rb_state_snapshots.set_at(tick, _Snapshot.of(tick, [[node, ^"position", position]], auth_subjects))

func set_rollback_states(tick: int, values: Array, auth_subjects: Array[Object]) -> void:
	var entries: Array[Array] = []
	for value in values:
		entries.append([value[0], ^"position", value[1]])
	servers.history_server()._rb_state_snapshots.set_at(tick, _Snapshot.of(tick, entries, auth_subjects))

func register_owner_state(sync_server: _NetworkSynchronizationServer, node: Node) -> void:
	servers.identity_server().register_node(node)
	sync_server.register_rollback_state(node, ^"position")
	sync_server.register_rollback_state(node, ^"scale", true)

func set_owner_states(tick: int, node: Node, position: Vector3, scale: Vector3) -> void:
	servers.history_server()._rb_state_snapshots.set_at(tick, _Snapshot.of(tick, [
		[node, ^"position", position], [node, ^"scale", scale]
	], [node]))

# Each rollback state sent to [param peer] as [tick, is full, values], read as
# [param peer] reads them
func sent_owner_states(sync_server: _NetworkSynchronizationServer, peer: int, node: Node) -> Array:
	var properties := _PropertyPool.of([[node, ^"position"], [node, ^"scale"]])
	var dense := _DenseSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())
	var sparse := _SparseSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())

	var result := []
	for command in servers.command_server().commands_sent:
		if command[2] != peer:
			continue
		var is_full: bool = command[0] == sync_server._cmd_full_state._idx
		if not is_full and command[0] != sync_server._cmd_diff_state._idx:
			continue
		var buffer := StreamPeerBuffer.new()
		buffer.data_array = command[1]
		var snapshot: _Snapshot
		if is_full:
			snapshot = dense.read_from(1, properties, buffer, true, sync_server._get_state_property_filter(peer))
		else:
			snapshot = sparse.read_from(1, properties, buffer)
		result.append([snapshot.tick, is_full, snapshot._data.get(node, {})])
	return result

# Each rollback state sent to [param peer] as [tick, is full, decoded snapshot]
func sent_states(sync_server: _NetworkSynchronizationServer, peer: int, nodes: Array) -> Array:
	var properties := _PropertyPool.new()
	for node in nodes:
		properties.add(node, ^"position")
	var dense := _DenseSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())
	var sparse := _SparseSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())

	var result := []
	for command in servers.command_server().commands_sent:
		if command[2] != peer:
			continue
		var is_full: bool = command[0] == sync_server._cmd_full_state._idx
		if not is_full and command[0] != sync_server._cmd_diff_state._idx:
			continue
		var buffer := StreamPeerBuffer.new()
		buffer.data_array = command[1]
		var snapshot := dense.read_from(1, properties, buffer) if is_full else sparse.read_from(1, properties, buffer)
		result.append([snapshot.tick, is_full, as_values(snapshot)])
	return result

# A snapshot as values that compare equal in an array
func as_values(snapshot: _Snapshot) -> Array:
	var auth_ids := []
	for subject in snapshot.get_auth_subjects():
		auth_ids.append(subject.get_instance_id())
	auth_ids.sort()
	return [snapshot.tick, snapshot._data, auth_ids]

# Each rollback state sent to [param peer] as [tick, is full]
func sent_state_ticks(sync_server: _NetworkSynchronizationServer, peer: int) -> Array:
	var result := []
	for command in servers.command_server().commands_sent:
		if command[2] != peer:
			continue
		if command[0] == sync_server._cmd_full_state._idx or command[0] == sync_server._cmd_diff_state._idx:
			var buffer := StreamPeerBuffer.new()
			buffer.data_array = command[1]
			result.append([buffer.get_u32(), command[0] == sync_server._cmd_full_state._idx])
	return result

func sent_diffs(sync_server: _NetworkSynchronizationServer, peer: int) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for command in servers.command_server().commands_sent:
		if command[0] == sync_server._cmd_diff_sync._idx and command[2] == peer:
			result.append(command[1])
	return result

func decode_diff(sync_server: _NetworkSynchronizationServer, data: PackedByteArray, nodes: Array) -> _Snapshot:
	var properties := _PropertyPool.new()
	for node in nodes:
		properties.add(node, ^"position")
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data
	var serializer := _SparseSnapshotSerializer.new(_NetworkSchema.new(), servers.identity_server())
	return serializer.read_from(1, properties, buffer)

func cleanup(sync_server: Node, nodes: Array) -> void:
	for node in nodes:
		NetworkHistoryServer.deregister(node)
		node.queue_free()
	sync_server.queue_free()

func get_node(name: String = "") -> Node3D:
	var node := Node3D.new()

	Vest.get_tree().root.add_child.call_deferred(node)
	await node.ready
	if name: node.name = name

	return node

class PeeredSynchronizationServer extends _NetworkSynchronizationServer:
	var peers := PackedInt32Array()

	func _get_peers() -> PackedInt32Array:
		return peers

	func _is_peer_connected(_node: Node, peer: int) -> bool:
		return peers.has(peer)
