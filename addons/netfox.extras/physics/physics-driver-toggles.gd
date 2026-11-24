extends Object

class PhysicsDriverToggle:
	const INACTIVE_SUFFIX := ".off"

	# Toggles refer to each other's files through these, not by instancing each
	# other: inner classes referring to each other form a reference cycle that
	# leaks every loaded script at exit
	const RAPIER_2D_FILES: Array[String] = [
		"res://addons/netfox.extras/physics/rapier_driver.gd",
		"res://addons/netfox.extras/physics/rapier_driver_2d.gd",
	]
	const RAPIER_3D_FILES: Array[String] = [
		"res://addons/netfox.extras/physics/rapier_driver.gd",
		"res://addons/netfox.extras/physics/rapier_driver_3d.gd",
	]

	func get_name() -> String:
		return "???"

	func get_files() -> Array[String]:
		return []

	func get_error_messages() -> Array[String]:
		return []

	func is_enabled() -> bool:
		return _files_exist(get_files())

	func _files_exist(files: Array[String]) -> bool:
		return files.all(func(it): return FileAccess.file_exists(it))

	func toggle() -> Array[String]:
		var errors := get_error_messages()
		if not errors.is_empty():
			return errors

		var enable := not is_enabled()

		var uid_files := get_files().map(func(it): return it + ".uid")
		var renames = (get_files() + uid_files).map(func(it):
			if enable: return [it + INACTIVE_SUFFIX, it]
			else: return [it, it + INACTIVE_SUFFIX]
		)

		for rename in renames:
			var result := DirAccess.rename_absolute(rename[0], rename[1])
			if result != OK:
				errors.append(
					"Failed rename \"%s\" -> \"%s\"; reason: %s" %
					[rename[0], rename[1], error_string(result)]
				)
		return errors

class Rapier2DPhysicsDriverToggle extends PhysicsDriverToggle:
	func get_name() -> String:
		return "Rapier2D"

	func get_files() -> Array[String]:
		return RAPIER_2D_FILES

	func get_error_messages() -> Array[String]:
		var messages := [] as Array[String]

		if _files_exist(RAPIER_3D_FILES):
			messages.append("Disable the Rapier3D driver before enabling 2D!")

		if not ClassDB.class_exists("RapierPhysicsServer2D"):
			messages.append("RapierPhysicsServer2D is not available! Is the extension installed?")

		return messages

class Rapier3DPhysicsDriverToggle extends PhysicsDriverToggle:
	func get_name() -> String:
		return "Rapier3D"

	func get_files() -> Array[String]:
		return RAPIER_3D_FILES

	func get_error_messages() -> Array[String]:
		var messages := [] as Array[String]

		if _files_exist(RAPIER_2D_FILES):
			messages.append("Disable the Rapier2D driver before enabling 3D!")

		if not ClassDB.class_exists("RapierPhysicsServer3D"):
			messages.append("RapierPhysicsServer3D is not available! Is the extension installed?")

		return messages

class GodotPhysicsDriverToggle extends PhysicsDriverToggle:
	func get_name() -> String:
		return "Godot"

	func get_files() -> Array[String]:
		return [
			"res://addons/netfox.extras/physics/godot_driver_3d.gd",
			"res://addons/netfox.extras/physics/godot_driver_2d.gd"
		]

	func get_error_messages() -> Array[String]:
		if not PhysicsServer3D.has_method("space_step") or not PhysicsServer2D.has_method("space_step"):
			return ["Physics stepping is not available! Is this the right Godot build?"]
		return []

static func all() -> Array[PhysicsDriverToggle]:
	return [
		Rapier2DPhysicsDriverToggle.new(),
		Rapier3DPhysicsDriverToggle.new(),
		GodotPhysicsDriverToggle.new()
	]
