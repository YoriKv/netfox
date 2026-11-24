extends VestTest

func get_suite_name() -> String:
	return "RollbackSynchronizer"

var spawn_root: SpawnAwareRollbackNode
var spawn_rbs: RollbackSynchronizer

func after_case(__) -> void:
	if is_instance_valid(spawn_root):
		NetworkHistoryServer.deregister(spawn_root)
		RollbackLivenessServer.deregister(spawn_root)
		spawn_root.queue_free()

	NetworkRollback._resim_from = NetworkTime.tick

func suite():
	test("Nested RollbackSynchronizer support", func():
		# Setup node layout:
		# 	primary_root/
		# 	├── primary_rbs
		# 	└── secondary_root/
		# 	    └── secondary_rbs

		var primary_root := RollbackAware.new(); primary_root.name = "Primary Root"
		var primary_rbs := RollbackSynchronizer.new(); primary_rbs.name = "Primary RBS"
		var secondary_root := RollbackAware.new(); secondary_root.name = "Secondary Root"
		var secondary_rbs := RollbackSynchronizer.new(); secondary_rbs.name = "Secondary RBS"

		primary_root.add_child(primary_rbs)
		primary_root.add_child(secondary_root)
		secondary_root.add_child(secondary_rbs)

		primary_rbs.root = primary_root
		secondary_rbs.root = secondary_root

		Vest.get_tree().root.add_child.call_deferred(primary_root)
		await primary_root.ready

		# Pick up managed nodes
		primary_rbs.process_settings()
		secondary_rbs.process_settings()

		# Check managed nodes
		expect_equal(primary_rbs._sim_nodes, [primary_root])
		expect_equal(secondary_rbs._sim_nodes, [secondary_root])

		print("Node tree:")
		primary_root.print_tree_pretty()
		print("Primary managed: %s" % [primary_rbs._sim_nodes])
		print("Secondary managed: %s" % [secondary_rbs._sim_nodes])

		# Cleanup
		primary_root.queue_free()
	)

	define("spawn tick behavior", func():
		test("should seed initial rollback state at spawn tick", func():
			var setup := await create_spawn_synchronizer(4, 21)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer

			rbs.process_authority()

			var snapshot := NetworkHistoryServer._get_rollback_state_snapshot(4)
			expect_not_null(snapshot)
			expect(snapshot.has_property(root, ^"tracked_value"))
			expect_equal(snapshot.get_property(root, ^"tracked_value"), 21)
			expect_equal(NetworkHistoryServer.get_latest_state_tick_for([root], 4), 4)
		)

		test("should register liveness using spawn tick", func():
			var setup := await create_spawn_synchronizer(6, 0)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer

			rbs.process_settings()

			expect(RollbackLivenessServer.is_alive(root, 6))
			expect_not(RollbackLivenessServer.is_alive(root, 5))
		)

		test("should reseed state and clear despawn when spawned", func():
			var setup := await create_spawn_synchronizer(2, 21)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer
			rbs.process_settings()

			rbs.despawn(5)
			root.tracked_value = 42
			rbs.spawn(7)

			var snapshot := NetworkHistoryServer._get_rollback_state_snapshot(7)
			expect_equal(rbs.spawn_tick, 7)
			expect(RollbackLivenessServer.is_alive(root, 8))
			expect_not_null(snapshot)
			expect_equal(snapshot.get_property(root, ^"tracked_value"), 42)
		)

		test("should request resimulation from spawn tick", func():
			var setup := await create_spawn_synchronizer(3, 0)
			NetworkRollback._resim_from = 12

			NetworkRollback.before_loop.emit()

			expect_equal(NetworkRollback._resim_from, 3)
		)
	)

	define("visibility filter", func():
		test("should be freed with synchronizer outside tree", func():
			var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
			for i in 16:
				RollbackSynchronizer.new().free()
			expect_equal(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans_before)
		)
	)

	define("schema", func():
		test("should keep schema after leaving tree", func():
			var setup := await create_spawn_synchronizer(0, 0)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer
			rbs.process_settings()
			var serializer := NetworkSchemas.int32()
			rbs.set_schema({ ":tracked_value": serializer })

			var parent := root.get_parent()
			parent.remove_child(root)
			parent.add_child(root)
			rbs.process_settings()

			expect_equal(NetworkSynchronizationServer._schemas._get_serializer(root, ^"tracked_value"), serializer)
		)

		test("should forget cleared schema", func():
			var setup := await create_spawn_synchronizer(0, 0)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer
			var serializer := NetworkSchemas.int32()
			rbs.set_schema({ ":tracked_value": serializer })

			rbs.clear_schema()
			rbs.process_settings()

			expect_not_equal(NetworkSynchronizationServer._schemas._get_serializer(root, ^"tracked_value"), serializer)
		)
	)

	define("tree", func():
		test("should not register after leaving tree", func():
			var setup := make_spawn_synchronizer(0, 0)
			var root := setup[0] as SpawnAwareRollbackNode

			# Leave before the deferred registration runs
			Vest.get_tree().root.add_child(root)
			Vest.get_tree().root.remove_child(root)
			await Vest.get_tree().process_frame

			expect_null(NetworkIdentityServer._get_identifier_of(root))
			expect_not(NetworkHistoryServer._rb_state_properties.has_subject(root), "State should not be registered!")
			expect_not(RollbackSimulationServer._callbacks.has(root), "Simulation should not be registered!")
			expect_not(RollbackLivenessServer.is_registered(root), "Liveness should not be registered!")
		)

		test("should register again on entering tree", func():
			var setup := await create_spawn_synchronizer(0, 0)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer
			var serializer := NetworkSchemas.int32()
			rbs.set_schema({ ":tracked_value": serializer })
			await Vest.get_tree().process_frame

			var parent := root.get_parent()
			parent.remove_child(root)
			expect_null(NetworkIdentityServer._get_identifier_of(root))
			expect_equal(rbs.spawn_tick, -1)

			parent.add_child(root)
			await Vest.get_tree().process_frame

			expect_equal(rbs.spawn_tick, NetworkTime.tick)
			expect_not_null(NetworkIdentityServer._get_identifier_of(root))
			expect(NetworkHistoryServer._rb_state_properties.has_subject(root), "State should be registered!")
			expect(NetworkSynchronizationServer._rb_state_properties.has_subject(root), "State should be synchronized!")
			expect(RollbackSimulationServer._callbacks.has(root), "Simulation should be registered!")
			expect(RollbackLivenessServer.is_registered(root), "Liveness should be registered!")
			expect_equal(rbs._liveness_nodes, [root] as Array[Node])
			expect_equal(NetworkSynchronizationServer._visibility_filters.get(root), rbs.visibility_filter)
			expect_equal(NetworkSynchronizationServer._schemas._get_serializer(root, ^"tracked_value"), serializer)
		)
	)

	define("despawn()", func():
		test("should warn once without liveness nodes", func():
			var root := RollbackAware.new()
			var rbs := RollbackSynchronizer.new()
			rbs.root = root
			root.add_child(rbs)
			Vest.get_tree().root.add_child.call_deferred(root)
			await root.ready
			rbs.process_settings()

			var logger := RecordingLogger.new()
			rbs._logger = logger
			rbs.despawn()
			rbs.despawn()

			expect_equal(logger.warnings.size(), 1)
			root.queue_free()
		)

		test("should not warn with liveness nodes", func():
			var setup := await create_spawn_synchronizer(0, 0)
			var rbs := setup[1] as RollbackSynchronizer
			rbs.process_settings()

			var logger := RecordingLogger.new()
			rbs._logger = logger
			rbs.despawn()

			expect_empty(logger.warnings)
		)
	)

	define("default spawn tick", func():
		test("should be current tick", func():
			NetworkMocks.set_tick(12, 3)
			var setup := await create_spawn_synchronizer(-1, 0)
			var rbs := setup[1] as RollbackSynchronizer

			expect_equal(rbs.spawn_tick, 12)
			NetworkMocks.set_tick(0, 0)
		)

		test("should be next tick in rollback", func():
			NetworkMocks.set_tick(12, 7)
			var setup := make_spawn_synchronizer(-1, 0)
			var root := setup[0] as SpawnAwareRollbackNode
			var rbs := setup[1] as RollbackSynchronizer

			NetworkMocks.in_rollback(func(): Vest.get_tree().root.add_child(root))

			expect_equal(rbs.spawn_tick, 8)
			NetworkMocks.set_tick(0, 0)
		)
	)

	# Messy to set up, keeping cases for later
	define("Input age and predicting", func():
		test("should return -1 on no input", func(): todo())
		test("should return 0 on recent input", func(): todo())
		test("should return positive on old input", func(): todo())
	)

	define("get_last_known_input()", func():
		test("should return -1 for no input", func(): todo())
		test("should return latest", func(): todo())
	)

	define("get_last_known_state()", func():
		test("should return -1 for no state", func(): todo())
		test("should return latest", func(): todo())
	)

class RollbackAware extends Node:
	func _rollback_tick(_dt: float, _t: int, _if: int) -> void:
		pass

	func _to_vest():
		return _to_string()

	func _to_string() -> String:
		return "RollbackAware:" + name

func create_spawn_synchronizer(spawn_tick: int, tracked_value: int) -> Array:
	make_spawn_synchronizer(spawn_tick, tracked_value)

	Vest.get_tree().root.add_child.call_deferred(spawn_root)
	await spawn_root.ready

	return [spawn_root, spawn_rbs]

func make_spawn_synchronizer(spawn_tick: int, tracked_value: int) -> Array:
	spawn_root = SpawnAwareRollbackNode.new()
	spawn_root.name = "Spawn Root"
	spawn_root.tracked_value = tracked_value

	spawn_rbs = RollbackSynchronizer.new()
	spawn_rbs.name = "Spawn RBS"
	spawn_rbs.root = spawn_root
	spawn_rbs.state_properties = [":tracked_value"]
	spawn_rbs.spawn_tick = spawn_tick

	spawn_root.add_child(spawn_rbs)

	return [spawn_root, spawn_rbs]

class RecordingLogger extends NetfoxLogger:
	var warnings := []

	func _init() -> void:
		super("netfox", "Recording")

	func warning(text: String, values: Array = []):
		warnings.append(text % values)

class SpawnAwareRollbackNode extends Node:
	var tracked_value := 0

	func _rollback_tick(_dt: float, _t: int, _if: int) -> void:
		pass

	func _rollback_spawn() -> void:
		pass

	func _rollback_despawn() -> void:
		pass

	func _rollback_destroy() -> void:
		pass
