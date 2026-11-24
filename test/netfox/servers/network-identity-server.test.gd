extends VestTest

func get_suite_name() -> String:
	return "NetworkIdentityServer"

var command_server: TestingCommandServer
var identity_server: _NetworkIdentityServer

var node: Node
var orphan_node: Node

func before_case(__):
	# Makes sure local peer is 1, otherwise identifiers get random local IDs
	Vest.get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	command_server = TestingCommandServer.new()
	identity_server = _NetworkIdentityServer.new(command_server)

	node = Node.new()
	node.name = "Identified Node"

	orphan_node = Node.new()

	Vest.get_tree().root.add_child.call_deferred(node)
	Vest.get_tree().root.add_child.call_deferred(command_server)
	Vest.get_tree().root.add_child.call_deferred(identity_server)

	await node.ready
	await command_server.ready
	await identity_server.ready

func after_case(__):
	identity_server.queue_free()
	command_server.queue_free()
	node.queue_free()
	orphan_node.queue_free()

func suite() -> void:
	define("register_node()", func():
		test("should register", func():
			# Register node
			identity_server.register_node(node)

			# Assert for identifier
			var identifier := identity_server._get_identifier_of(node)
			expect_not_null(identifier)
			expect_equal(identifier.get_full_name(), "/root/Identified Node")
		)

		test("should fail on node node in tree", func():
			# Register node
			identity_server.register_node(orphan_node)

			# Assert for identifier
			var identifier := identity_server._get_identifier_of(orphan_node)
			expect_null(identifier)
		)
	)

	define("deregister_node()", func():
		test("should remove known", func():
			# Register node
			identity_server.register_node(node)
			expect_not_null(identity_server._get_identifier_of(node))

			# Deregister
			identity_server.deregister_node(node)
			expect_null(identity_server._get_identifier_of(node))
		)

		test("should do nothing on unknown", func():
			identity_server.deregister_node(orphan_node)
			expect_null(identity_server._get_identifier_of(orphan_node))
		)
	)

	define("flush_queue()", func():
		test("should send ids", func():
			# Register node
			identity_server.register_node(node)

			var identifier := identity_server._get_identifier_of(node)
			var full_name := identifier.get_full_name()

			# Try and resolve some unknown identities
			identity_server._resolve_reference(2, identifier.reference_for(2))
			identity_server._resolve_reference(3, identifier.reference_for(3))

			# Flush queue
			identity_server.flush_queue()

			# Check commands sent
			expect_equal(command_server.commands_sent.size(), 2)
			for i in command_server.commands_sent.size():
				var command := command_server.commands_sent[i]

				expect_equal(command[0], 0)							# Command id
				expect_equal(command[2], 2 + i)						# Peer
				expect_equal(command[3], MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		)
	)

	define("_resolve_reference()", func():
		test("should return by id", func():
			# Register node
			identity_server.register_node(node)
			var identifier := identity_server._get_identifier_of(node)

			# Resolve
			var reference := _NetworkIdentityReference.of_id(identifier.get_local_id())
			expect_equal(identity_server._resolve_reference(1, reference), identifier)
		)

		test("should return by name", func():
			# Register node
			identity_server.register_node(node)
			var identifier := identity_server._get_identifier_of(node)

			# Resolve
			var reference := _NetworkIdentityReference.of_full_name(identifier.get_full_name())
			expect_equal(identity_server._resolve_reference(1, reference), identifier)
		)

		test("should return null on unknown", func():
			var reference := _NetworkIdentityReference.of_full_name("Unknown Node")
			expect_null(identity_server._resolve_reference(1, reference))
		)
	)

	define("_is_recently_deregistered()", func():
		test("should be true for deregistered", func():
			identity_server.register_node(node)
			var identifier := identity_server._get_identifier_of(node)
			var by_id := _NetworkIdentityReference.of_id(identifier.get_local_id())
			var by_name := _NetworkIdentityReference.of_full_name(identifier.get_full_name())

			identity_server.deregister_node(node)

			expect(identity_server._is_recently_deregistered(by_id), "Should be true by id!")
			expect(identity_server._is_recently_deregistered(by_name), "Should be true by name!")
		)

		test("should be false for unknown", func():
			var by_id := _NetworkIdentityReference.of_id(37)
			var by_name := _NetworkIdentityReference.of_full_name("Unknown Node")

			expect_not(identity_server._is_recently_deregistered(by_id), "Should be false by id!")
			expect_not(identity_server._is_recently_deregistered(by_name), "Should be false by name!")
		)

		test("should be false past history limit", func():
			NetworkMocks.set_network_tick(10)
			identity_server.register_node(node)
			var identifier := identity_server._get_identifier_of(node)
			var by_id := _NetworkIdentityReference.of_id(identifier.get_local_id())
			identity_server.deregister_node(node)

			NetworkMocks.set_network_tick(10 + NetworkRollback.history_limit + 1)
			var is_deregistered := identity_server._is_recently_deregistered(by_id)
			NetworkMocks.set_network_tick(0)

			expect_not(is_deregistered)
		)

		test("should forget old entries", func():
			NetworkMocks.set_network_tick(10)
			identity_server.register_node(node)
			identity_server.deregister_node(node)

			NetworkMocks.set_network_tick(10 + NetworkRollback.history_limit + 1)
			Vest.get_tree().root.add_child(orphan_node)
			identity_server.register_node(orphan_node)
			identity_server.deregister_node(orphan_node)
			NetworkMocks.set_network_tick(0)

			expect_equal(identity_server._deregistered_by_local_id.size(), 1)
			expect_equal(identity_server._deregistered_by_name.size(), 1)
		)

		test("should be false once registered again", func():
			identity_server.register_node(node)
			var by_name := _NetworkIdentityReference.of_full_name(identity_server._get_identifier_of(node).get_full_name())
			identity_server.deregister_node(node)

			identity_server.register_node(node)

			expect_not(identity_server._is_recently_deregistered(by_name))
		)
	)

	define("leaks", func():
		test("should free identifiers on deregister", func():
			# Warm up caches
			_register_and_deregister()

			var objects_before := Performance.get_monitor(Performance.OBJECT_COUNT)
			for i in 64:
				_register_and_deregister()

			expect_equal(Performance.get_monitor(Performance.OBJECT_COUNT), objects_before)
			expect(identity_server._identifier_by_id.is_empty(), "ID cache should be empty")
		)
	)

# Register node, receive an ID for it from a peer, then deregister it
func _register_and_deregister() -> void:
	identity_server.register_node(node)
	var full_name := identity_server._get_identifier_of(node).get_full_name()
	identity_server._handle_ids(2, identity_server._packet_serializer.serialize({ full_name: 7 }))
	identity_server.deregister_node(node)
