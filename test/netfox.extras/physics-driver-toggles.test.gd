extends VestTest

const PhysicsDriverToggles := preload("res://addons/netfox.extras/physics/physics-driver-toggles.gd")

func get_suite_name() -> String:
	return "PhysicsDriverToggles"

func suite() -> void:
	test("Rapier drivers should be disabled", func():
		for toggle in PhysicsDriverToggles.all():
			if toggle.get_name().begins_with("Rapier"):
				expect_not(toggle.is_enabled(), "%s should be disabled!" % [toggle.get_name()])
	)

	test("Rapier drivers should need their extension", func():
		expect_contains(
			PhysicsDriverToggles.Rapier2DPhysicsDriverToggle.new().get_error_messages(),
			"RapierPhysicsServer2D is not available! Is the extension installed?"
		)
		expect_contains(
			PhysicsDriverToggles.Rapier3DPhysicsDriverToggle.new().get_error_messages(),
			"RapierPhysicsServer3D is not available! Is the extension installed?"
		)
	)
