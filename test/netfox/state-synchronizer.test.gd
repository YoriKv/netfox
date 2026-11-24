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

func create_synchronizer() -> void:
	root = StatefulNode.new()
	root.name = "Stateful Node"

	synchronizer = StateSynchronizer.new()
	synchronizer.name = "StateSynchronizer"
	synchronizer.root = root
	synchronizer.properties = [":value"]
	root.add_child(synchronizer)

	Vest.get_tree().root.add_child.call_deferred(root)
	await root.ready

class StatefulNode extends Node:
	var value := 0
