extends VestTest

func get_suite_name():
	return "RewindableAction"

var rewindable_action: RewindableAction

func before_case(__) -> void:
	rewindable_action = RewindableAction.new()
	await Vest.sleep()
	NetworkTime.get_tree().root.add_child(rewindable_action)
	NetworkRollback.reset()

func after_case(__) -> void:
	rewindable_action.free()

func test_should_empty_queue_after_loop():
	# Run as client
	rewindable_action.set_multiplayer_authority(2)

	# Prepare changes
	var tickset := _Set.of([0])
	var data := _TicksetSerializer.serialize(0, 4, tickset)
	NetworkMocks.set_tick(4, 4)

	# Run first loop
	rewindable_action._submit_state(data)	# Server sends data
	NetworkMocks.run_network_tick_loop()
	expect(rewindable_action.has_confirmed(), "RewindableAction was not confirmed!")

	# Run second loop
	rewindable_action._submit_state(data)	# Server sends data again
	NetworkMocks.run_network_tick_loop()
	expect_not(rewindable_action.has_confirmed(), "RewindableAction was redundantly confirmed!")

func test_should_send_to_every_peer_without_filter():
	var recorder := RecordingMultiplayer.new()
	Vest.get_tree().set_multiplayer(recorder, rewindable_action.get_path())

	rewindable_action.set_active(true, 0)
	rewindable_action._after_loop()
	Vest.get_tree().set_multiplayer(null, rewindable_action.get_path())

	expect_equal(recorder.rpcs, [[0, &"_submit_state"]])

func test_should_send_to_visible_peers_with_filter():
	var recorder := RecordingMultiplayer.new()
	Vest.get_tree().set_multiplayer(recorder, rewindable_action.get_path())

	var filter := PeerVisibilityFilter.new()
	rewindable_action.add_child(filter)
	filter.update_mode = PeerVisibilityFilter.UpdateMode.NEVER
	filter.default_visibility = false
	filter.set_visibility_for(3, true)
	filter.update_visibility()
	rewindable_action.visibility_filter = filter

	rewindable_action.set_active(true, 0)
	rewindable_action._after_loop()
	Vest.get_tree().set_multiplayer(null, rewindable_action.get_path())

	expect_equal(recorder.rpcs, [[3, &"_submit_state"]])

# Records RPCs instead of sending them, for a server with peers 2, 3 and 4
class RecordingMultiplayer extends MultiplayerAPIExtension:
	var rpcs := []
	var _peer: MultiplayerPeer = OfflineMultiplayerPeer.new()

	func _poll() -> Error: return OK
	func _set_multiplayer_peer(p_peer: MultiplayerPeer) -> void: _peer = p_peer
	func _get_multiplayer_peer() -> MultiplayerPeer: return _peer
	func _get_unique_id() -> int: return 1
	func _get_peer_ids() -> PackedInt32Array: return PackedInt32Array([2, 3, 4])
	func _get_remote_sender_id() -> int: return 0
	func _object_configuration_add(_object: Object, _configuration: Variant) -> Error: return OK
	func _object_configuration_remove(_object: Object, _configuration: Variant) -> Error: return OK

	func _rpc(peer: int, _object: Object, method: StringName, _args: Array) -> Error:
		rpcs.append([peer, method])
		return OK
