extends Node
class_name _NetworkIdentityServer

# @public class

## Tracks identities for use over the network
##
## Internally, netfox sends packets that refer to specific nodes, e.g. to
## synchronize their state. Nodes are referenced based on their path in the
## scene tree. To save on bandwidth, node paths are replaced with numeric IDs
## when possible.
## [br][br]
## This class manages these numerical IDs and their broadcast among peers.
## [br][br]
## Each node that is to be referred to over the network must be registered using
## [method register_node]. It is best to deregister freed nodes using [method
## deregister_node].
## [br][br]
## Node registration and deregistration are done automatically by the high-level
## nodes ( like RollbackSynchronizer ), and usually doesn't need to be done
## manually.

var _command_server: _NetworkCommandServer

var _next_id := 0
var _identifiers := {} # object to NetworkIdentifier
var _push_queue := {} # peer to (full name to id)

var _identifier_by_name := {} # full name to NetworkIdentifier
var _identifier_by_id := {} # peer to (id to NetworkIdentifier)
var _identifier_by_local_id := {} # local id to NetworkIdentifier

# Identities deregistered recently, so data still in flight for them can be
# dropped quietly
var _deregistered_by_name := {} # full name to tick of deregistering
var _deregistered_by_local_id := {} # local id to tick of deregistering

var _cmd_ids: _NetworkCommandServer.Command
var _packet_serializer := _IdentityPacketSerializer.new()

var _has_warned_queue_length := false

static var _logger := NetfoxLogger._for_netfox("NetworkIdentityServer")

const _WARN_QUEUE_SIZE := 128

func _init(p_command_server: _NetworkCommandServer = null) -> void:
	_command_server = p_command_server

func _ready() -> void:
	if not _command_server:
		_command_server = NetworkCommandServer

	_cmd_ids = _command_server.register_command(_handle_ids, MultiplayerPeer.TRANSFER_MODE_RELIABLE)

	if NetworkEvents.enabled:
		NetworkEvents.on_peer_leave.connect(erase_peer)
	else:
		multiplayer.peer_disconnected.connect(erase_peer)
		if not ProjectSettings.get_setting("netfox/general/supress_identity_peer_disconnected_warning", false):
			_logger.warning(
				"Using `multiplayer.peer_disconnected` to detect leaving peers. " +
				"If the `multiplayer` instance changes, this will no longer work. " +
				"Enable NetworkEvents, or call `NetworkIdentityServer.erase_peer()` " +
				"manually and disable this warning in the Project Settings. " +
				"( Netfox > General > Supress Identity Peer Disconnected Warning)"
			)

# TODO(#561): Handle peer disconnect by clearing up data

## Register a node
## [br][br]
## Once a node is registered, it can be referred to over the network. The same
## node must be registered with the same node path on all peers.
func register_node(node: Node) -> void:
	if not node.is_inside_tree():
		_logger.error("Can't register node %s that is not inside tree!", [node])
		return
	_register(node, node.get_path())

## Deregister a node, freeing all identity data associated with it
func deregister_node(node: Node) -> void:
	_deregister(node)

## Free all identity data associated with [param peer]
## [br][br]
## Does nothing if [param peer] is unknown, or the local peer.
func erase_peer(peer: int) -> void:
	_logger.debug("Erasing data for peer #%d", [peer])

	_push_queue.erase(peer)
	_identifier_by_id.erase(peer)
	for identifier in _identifiers.values():
		(identifier as _NetworkIdentifier).erase_id_for(peer)

## Free the identity data of [param node] associated with [param peer]
## [br][br]
## Until [param peer] sends its ID for [param node] again, [param node] is
## referred to by its full name in packets sent to [param peer]. Call this when
## [param peer] frees its copy of [param node] while the local one stays, e.g.
## when the node leaves the peer's relevance, so the ID of the freed copy is not
## used for the one [param peer] makes later.
func erase_node_for(node: Node, peer: int) -> void:
	var identifier := _get_identifier_of(node)
	if not identifier:
		return

	if identifier.has_id_for(peer):
		var cache := _identifier_by_id.get(peer, {}) as Dictionary
		cache.erase(identifier.get_id_for(peer))
		if cache.is_empty():
			_identifier_by_id.erase(peer)
		identifier.erase_id_for(peer)

	if _push_queue.has(peer):
		var queue := _push_queue[peer] as Dictionary
		queue.erase(identifier.get_full_name())
		if queue.is_empty():
			_push_queue.erase(peer)

## Clear all identities
func clear() -> void:
	_identifiers.clear()
	_identifier_by_name.clear()
	_identifier_by_id.clear()
	_identifier_by_local_id.clear()
	_deregistered_by_name.clear()
	_deregistered_by_local_id.clear()
	_push_queue.clear()
	_next_id = 0

## Queue sending the numeric ID of [param node] to [param peer]
## [br][br]
## This happens automatically when the [param node] is first referred to in a
## packet. This method allows frontloading that, at a more feasible moment.
## [br][br]
## This method does not send any data. To force sending identifiers, use [method
## flush_queue].
func queue_identifier_for(node: Node, peer: int) -> bool:
	var identifier := _get_identifier_of(node)
	if not identifier:
		return false
	_queue_for(identifier, peer)
	return true

## Broadcast all identities queued for synchronization
## [br][br]
## Flushed automatically by default
func flush_queue() -> void:
	for peer in _push_queue:
		_cmd_ids.send(_packet_serializer.serialize(_push_queue[peer]), peer)
	_push_queue.clear()

func _get_identifier_of(what: Object) -> _NetworkIdentifier:
	return _identifiers.get(what)

# Return true if [param identity_reference] could not be resolved because it
# refers to an identity deregistered within the rollback history limit
func _is_recently_deregistered(identity_reference: _NetworkIdentityReference) -> bool:
	var deregistered_at := -1
	if identity_reference.has_id():
		deregistered_at = _deregistered_by_local_id.get(identity_reference.get_id(), -1)
	else:
		deregistered_at = _deregistered_by_name.get(identity_reference.get_full_name(), -1)
	return deregistered_at >= 0 and _is_recent(deregistered_at, NetworkTime.tick)

func _resolve_reference(peer: int, identity_reference: _NetworkIdentityReference, allow_queue: bool = true) -> _NetworkIdentifier:
	if identity_reference.has_id():
		return _get_identifier_by_local_id(identity_reference.get_id())
	else:
		var identifier := _get_identifier_by_name(identity_reference.get_full_name())
		if allow_queue and identifier:
			_queue_for(identifier, peer)
		return identifier

func _queue_for(identifier: _NetworkIdentifier, peer: int) -> void:
	if not _push_queue.has(peer):
		_push_queue[peer] = { identifier.get_full_name(): identifier.get_local_id() }
	else:
		_push_queue[peer][identifier.get_full_name()] = identifier.get_local_id()

	var queue_size := _push_queue[peer].size() as int
	if not _has_warned_queue_length and queue_size >= _WARN_QUEUE_SIZE:
		_has_warned_queue_length = true
		_logger.warning("Queue size for peer #%d exceeded %d - is the queue being flushed?", [peer, _push_queue[peer].size()])

func _register(what: Object, path: String) -> void:
	if _identifiers.has(what):
		return

	var identifier := _NetworkIdentifier.new(what, path, _make_id())
	_identifiers[what] = identifier
	_identifier_by_name[identifier.get_full_name()] = identifier
	_identifier_by_local_id[identifier.get_local_id()] = identifier
	_deregistered_by_name.erase(identifier.get_full_name())

func _deregister(what: Object) -> void:
	if not _identifiers.has(what):
		return

	var identifier := _identifiers[what] as _NetworkIdentifier
	_identifiers.erase(what)
	_identifier_by_name.erase(identifier.get_full_name())
	_identifier_by_local_id.erase(identifier.get_local_id())
	_erase_from_id_cache(identifier)
	_remember_deregistered(identifier)

func _remember_deregistered(identifier: _NetworkIdentifier) -> void:
	var tick := NetworkTime.tick

	# Forget old entries as we go
	for full_name in _deregistered_by_name.keys():
		if not _is_recent(_deregistered_by_name[full_name], tick):
			_deregistered_by_name.erase(full_name)
	for local_id in _deregistered_by_local_id.keys():
		if not _is_recent(_deregistered_by_local_id[local_id], tick):
			_deregistered_by_local_id.erase(local_id)

	_deregistered_by_name[identifier.get_full_name()] = tick
	_deregistered_by_local_id[identifier.get_local_id()] = tick

# A tick after the current one is from before the clock was reset
func _is_recent(deregistered_at: int, tick: int) -> bool:
	return deregistered_at <= tick and tick - deregistered_at <= NetworkRollback.history_limit

func _get_identifier_by_name(full_name: String) -> _NetworkIdentifier:
	return _identifier_by_name.get(full_name)

func _get_identifier_by_local_id(local_id: int) -> _NetworkIdentifier:
	return _identifier_by_local_id.get(local_id, null)

func _make_id() -> int:
	_next_id += 1
	return _next_id

func _update_id_cache(identifier: _NetworkIdentifier, peer: int, id: int) -> void:
	if not _identifier_by_id.has(peer):
		_identifier_by_id[peer] = { id: identifier }
	else:
		_identifier_by_id[peer][id] = identifier

func _erase_from_id_cache(identifier: _NetworkIdentifier) -> void:
	for peer in identifier.get_known_peers():
		if not _identifier_by_id.has(peer):
			# nani?
			continue

		var cache := _identifier_by_id.get(peer) as Dictionary
		cache.erase(identifier.get_id_for(peer))
		if cache.is_empty():
			_identifier_by_id.erase(peer)

func _handle_ids(sender: int, data: PackedByteArray) -> void:
	var ids := _packet_serializer.deserialize(data)

	for full_name in ids:
		var id := ids[full_name] as int
		_logger.info("Received ID #%d for %s from #%d", [id, full_name, sender])
		var identifier := _get_identifier_by_name(full_name)
		if not identifier:
			# Deleted since then
			_logger.debug("Received identifier for unknown object with full name %s, id #%d", [full_name, id])
			continue
		identifier.set_id_for(sender, id)
		_update_id_cache(identifier, sender, id)
