# StateSynchronizer

Synchronizes state from the node's authority to other peers.

Similar to Godot's [MultiplayerSynchronizer], but is tied to the [network tick
loop]. Works well with [TickInterpolator].

One way to use this node is to synchronize logic that runs only on the server,
for example NPC's in your games. The NPC's are controlled fully by the server,
and their state is synchronized to the clients by the *StateSynchronizer*
nodes.

## Configuring state

To use *StateSynchronizer*, add it as a child to the target node, specify the
root node, and configure which properties to synchronize:

![StateSynchronizer configuration](../assets/state-synchronizer-config.png)

*Root* specifies the root node for resolving properties. Best practice dictates
to add *StateSynchronizer* under its target, so *Root* will most often be the
*StateSynchronizer*'s parent node.

*Properties* are recorded for each tick on the node's authority ( usually the
server ), and broadcast to other peers. These are analogous to
[RollbackSynchronizer]'s *state properties*.

See [Property paths] on how to specify properties.

*Send interval* is the number of ticks between sending the state. The
properties are recorded and sent at the ticks divisible by it, so every
synchronizer with the same interval sends at the same ticks, in one packet per
peer: a crowd of NPC's sent every few ticks costs a packet per peer every few
ticks, instead of one every tick. In between, the authority neither records
nor sends their state, and keeps its own values. A diff state holds what
changed since the state last sent, and a node newly visible to a peer, or due a
full state, is sent in full at its next sending tick. Set the same interval on
every peer: [TickInterpolator] uses it to spread each state received over the
interval.

*Stagger sends* gives each node of the synchronizer a phase of its own within
the send interval instead: the nodes of all synchronizers with it on are sent in
turn, a share of them every tick, in one packet per peer per tick. The packets
cost more headers, but the authority's work is spread evenly over the ticks
instead of falling on one tick in every interval, which matters for a large
crowd.

## Changing configuration

*StateSynchronizer* has to do some setup work whenever the state or the
input properties change.

By default, this work is done upon instantiation. If you need to change
properties during runtime, make sure to call `process_settings()`, otherwise
*StateSynchronizer* won't apply the changes.

You can change the node's authority without calling `process_settings()` again.
Make sure that the authority is changed the same way on all peers, to avoid
discrepancies.

## When to use StateSynchronizer and MultiplayerSynchronizer

Part of the design philosophy of netfox is to build *on top of* Godot's
networking tools, instead of *replacing* them.

Both [MultiplayerSynchronizer] and StateSynchronizer can be used to synchronize
state from authority to the rest of the peers.

[MultiplayerSynchronizer] uses its own timer, and is independent of netfox's
[network tick loop]. It can also do delta updates, and manage visibility per
peer. Since it is not tied to netfox's tick loop, it does not work with
[TickInterpolator].

StateSynchronizer records all the properties specified and broadcasts them
to all peers its visibility filter lets through, as diff states. The broadcast
happens on every network tick, or every *Send interval* ticks. This node is
explicitly designed to work with [TickInterpolator].

---

You can use StateSynchronizer for properties that you want to be interpolated,
like position, rotation, or any other visual properties.

You can use [MultiplayerSynchronizer] for properties that either don't need
interpolation ( e.g. a unit's HP ), or specifically need one of
[MultiplayerSynchronizer]'s features.

[MultiplayerSynchronizer]: https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html
[network tick loop]: ../guides/network-time.md
[TickInterpolator]: ./tick-interpolator.md
[RollbackSynchronizer]: ./rollback-synchronizer.md
[Property paths]: ../guides/property-paths.md
