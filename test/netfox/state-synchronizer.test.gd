extends VestTest

func get_suite_name() -> String:
	return "StateSynchronizer"

var root: StatefulNode
var synchronizer: StateSynchronizer

func after_case(__) -> void:
	if is_instance_valid(root):
		root.queue_free()

func suite():
	define("visibility filter", func():
		test("should be freed with synchronizer outside tree", func():
			var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
			for i in 16:
				StateSynchronizer.new().free()
			expect_equal(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans_before)
		)
	)

	define("schema", func():
		test("should keep schema after leaving tree", func():
			await create_synchronizer()
			synchronizer.process_settings()
			var serializer := NetworkSchemas.int32()
			synchronizer.set_schema({ ":value": serializer })

			var parent := root.get_parent()
			parent.remove_child(root)
			parent.add_child(root)
			synchronizer.process_settings()

			expect_equal(NetworkSynchronizationServer._schemas._get_serializer(root, ^"value"), serializer)
		)
	)

	define("tree", func():
		test("should not register after leaving tree", func():
			make_synchronizer()

			# Leave before the deferred registration runs
			Vest.get_tree().root.add_child(root)
			Vest.get_tree().root.remove_child(root)
			await Vest.get_tree().process_frame

			expect_null(NetworkIdentityServer._get_identifier_of(root))
			expect_not(NetworkHistoryServer._sync_state_properties.has_subject(root), "State should not be registered!")
			expect_not(NetworkSynchronizationServer._sync_state_properties.has_subject(root), "State should not be synchronized!")
		)

		test("should register again on entering tree", func():
			await create_synchronizer()
			var serializer := NetworkSchemas.int32()
			synchronizer.set_schema({ ":value": serializer })
			await Vest.get_tree().process_frame

			var parent := root.get_parent()
			parent.remove_child(root)
			expect_null(NetworkIdentityServer._get_identifier_of(root))

			parent.add_child(root)
			await Vest.get_tree().process_frame

			expect_not_null(NetworkIdentityServer._get_identifier_of(root))
			expect(NetworkHistoryServer._sync_state_properties.has_subject(root), "State should be registered!")
			expect(NetworkSynchronizationServer._sync_state_properties.has_subject(root), "State should be synchronized!")
			expect_equal(NetworkSynchronizationServer._visibility_filters.get(root), synchronizer.visibility_filter)
			expect_equal(NetworkSynchronizationServer._schemas._get_serializer(root, ^"value"), serializer)
		)
	)

func create_synchronizer() -> void:
	make_synchronizer()

	Vest.get_tree().root.add_child.call_deferred(root)
	await root.ready

func make_synchronizer() -> void:
	root = StatefulNode.new()
	root.name = "Stateful Node"

	synchronizer = StateSynchronizer.new()
	synchronizer.name = "StateSynchronizer"
	synchronizer.root = root
	synchronizer.properties = [":value"]
	root.add_child(synchronizer)

class StatefulNode extends Node:
	var value := 0
