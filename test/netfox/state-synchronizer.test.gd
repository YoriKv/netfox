extends VestTest

func get_suite_name() -> String:
	return "StateSynchronizer"

func suite():
	define("visibility filter", func():
		test("should be freed with synchronizer outside tree", func():
			var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
			for i in 16:
				StateSynchronizer.new().free()
			expect_equal(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans_before)
		)
	)
