# NetworkRollback

Orchestrates the network rollback loop. Provided as an autoload.

Due to latency, the server may receive inputs from clients from multiple ticks
ago. Whenever this happens, the server rewinds its time and resimulates the
whole game from the time of the new input. The resimulated ticks are then sent
to clients to update their state.

Also due to latency, clients may receive a state from the server that is
several ticks old. Clients rewind their simulation to the time of the latest
received state and resimulate from there.

On both clients and servers, simulated states are recorded for reuse later.

Further reading: [Client-Side Prediction and Server Reconciliation]

Note that most of the time you do not need to use this class - the
[RollbackSynchronizer] node helps with writing rollback-aware behaviour.

## Network rollback loop

*NetworkRollback* runs the *network rollback loop* after every network tick,
but before the *after tick* signal is fired.

The following is the network rollback loop in isolation:

```puml
@startuml

start

:before_loop;
while(Rollback)
  :on_prepare_tick;
  :after_prepare_tick;
  :on_process_tick;
  :on_record_tick;
endwhile
:after_loop;

stop

@enduml
```

Signal handlers must implement the right steps for rollback to work.

During *before_loop*, all rollback-aware nodes must submit where to start the
resimulation, by calling `NetworkRollback.notify_resimulation_start`.
Resimulation will begin from the earliest tick submitted.

In each *on_prepare_tick(tick)* handler, nodes must rewind their state to the
specified tick. If a state is not available for the given tick, use the latest
tick that is earlier than the given tick. Nodes may also register themselves as
being simulated by calling `NetworkRollback.notify_simulated`. This is not used
by *NetworkRollback* itself, but can be used by other nodes to check which
nodes are simulated in the current rollback tick.

Before processing, *after_prepare_tick(tick)* is emitted. This is where any
additional state- or input preparation may happen, such as [input prediction].

For the *on_process_tick(tick)* signal, nodes must advance their simulation by
a single tick.

In *on_record_tick(tick)*, nodes must record their state for the given tick.
Note that since the simulation was advanced by one tick in the previous signal,
the *tick* parameter is incremented here.

The *after_loop* signal notifies its subscribers that the resimulation is done.
This can be used to change to the state that is appropriate for display.

The network rollback loop is part of the network tick loop as follows:

```puml
@startuml

start

:NetworkTime.before_tick_loop;

while (Ticks to simulate)  is (>0)
  :NetworkTime.before_tick;
  :NetworkTime.on_tick;
  :NetworkTime.after_tick;
endwhile

:NetworkRollback.before_loop;
while(Rollback)
  :NetworkRollback.on_prepare_tick;
  :NetworkRollback.after_prepare_tick;
  :NetworkRollback.on_process_tick;
  :NetworkRollback.on_record_tick;
endwhile
:NetworkRollback.after_loop;

:NetworkTime.after_tick_loop;

stop

@enduml
```

The rollback tick loop is triggered in the `NetworkTime.after_tick_loop`
signal. Since the rollback tick loop is the first thing connected to it, in
practice the rollback will run *before* any user code connected to the
`after_tick_loop` signal.

## Conditional simulation

During rollback, *NetworkRollback* loops over the full range of ticks to
resimulate. Some nodes may not need to be resimulated for the current tick,
e.g. because they don't have input for the current tick.

*NetworkRollback* can be used to track nodes that will be simulated in the
current rollback tick. Register nodes that will be simulated by calling
`NetworkRollback.notify_simulated`. To check if a node has been registered,
call `NetworkRollback.is_simulated`.

## Rollback-awareness

[RollbackSynchronizer] considers nodes rollback-aware that implement the
`_rollback_tick` method. Rollback-aware nodes are nodes that can participate in
the rollback process, i.e. they can resimulate earlier ticks.

To check if a node is rollback-aware, call `NetworkRollback.is_rollback_aware`.
To actually run a rollback tick on them, call
`NetworkRollback.process_rollback`.

These methods are called by [RollbackSynchronizer] under the hood.

## Input Submission Status

In certain scenarios you may wish to delay committing to something hard to
reverse like death, VFX or audio until its known for sure the outcome won't
change. One way of doing this is to check which nodes have submitted input and
are past a point of rollback.

You can query the status of Nodes with
`NetworkRollback.get_latest_input_tick(root_node)` or
`NetworkRollback.has_input_for_tick(root_node, tick)`. `root_node` being what
the relevant [RollbackSynchronizer] has configured.

All tracked nodes can be retrieved from
`NetworkRollback.get_input_submissions()` which will return the entire
`<root_node, latest_tick>` dictionary.

## Corrections

When a peer receives an authoritative state for a node it simulates - it owns
one of the node's inputs, the node has no input, or prediction is enabled for
it - and the state differs from the one it recorded for the same tick, the
peer's prediction was wrong. *NetworkRollback* emits `on_correction(node, tick,
properties)` for each such node, with `properties` mapping each property path
that differed to `[recorded, received]`. Nothing is compared while the signal
has no connections and performance monitoring is disabled.

The signal fires as the state is received, before the rollback loop that
resimulates from it. Use it to log which properties diverge, or to smooth the
displayed correction.

## Settings

![Network rollback settings](../assets/network-rollback-settings.png)

*Enabled* toggles network rollback. No signals are fired when disabled.

*History limit* is the maximum number of recorded ticks to keep. Larger values
enable further rewinds and thus larger latencies, but consume more memory for
each node that is recorded.

*Input redundancy* This is the number of previous input ticks to send along with 
the current tick. We send data unreliably over UDP for speed. In the event a packet is
 lost or arrives out of order we add some redundancy. You can calculate your target
 reliability % packet success chance by using the formula 
 `1 - (1 - packet_success_rate) ^ input_redundancy`.

*Display offset* specifies the age of the tick to display. By displaying an
older state instead of the latest one, games can mask adjustments if a state
update is received from the server. The drawback is that the game will have
some latency built-in, as it reacts to player inputs with some delay. Setting
to zero will always display the latest game state.

*Input delay* specifies the delay applied to player input, in ticks. This
results in player inputs shifted into the future, e.g. if the player starts
moving left on tick 37, it will be sent to the server as tick 39. This way,
even if the input takes time to arrive, it will still be up to date, as long as
the network latency is smaller than the input latency.

!!!warning
    [RollbackSynchronizer]'s `is_fresh` parameter may not work as expected with
    input delay. This happens because clients already receive data for the
    current tick, which means that the tick doesn't need to be resimulated, and
    as a result, no `_rollback_tick` callbacks are ran with `is_fresh` set to
    true.

    This happens when network latency is smaller than the input delay.

*Input max late ticks* is how many ticks before the current one input is
still accepted for. Older input is refused: it is not recorded and starts no
resimulation, so a slow or misbehaving client cannot make every loop rewind
far. Set it from the lateness the worst supported connection shows, see the
*Input lateness* monitors in [NetworkPerformance]. Defaults to -1, which accepts
input as old as the *History limit*.

*Input max early ticks* is how many ticks after the current one, plus the
*Input delay*, input is accepted for. The current tick is taken from the
reference clock when the tick loop lags behind it, e.g. while catching up after
a hitch. Input further ahead is refused, and so are states received further
ahead: such a tick would push the earlier ticks out of the history. Set to -1 to
accept any tick.

A refused input emits `NetworkSynchronizationServer.on_input_refused(peer,
tick)` and is counted per peer by [NetworkPerformance]. Late copies of input
already received, e.g. from input redundancy, are dropped without a refusal.

*Resimulate on remote state* decides what a received state resimulates from.
On, the default, any state that changes the recorded history starts a
resimulation from its tick. Off, only a changed state of a node this peer
simulates does - it owns one of the node's inputs, the node has no input, or
prediction is enabled for it. A state of any other node, e.g. another player's
avatar on a client, is merged into the history and copied to the ticks recorded
after it, up to the next state received, as a resimulation would record them:
every tick restores the newest state received at or before it. This peer's own
nodes are not resimulated against it; they meet it from the next tick they are
simulated, and the server's states correct any difference. This saves most of a
client's rollback ticks while other players move in view.

A state of such a node can still change what this peer simulates, e.g. when
another player's avatar pushes into the local one. Set
`NetworkRollback.remote_state_interacts` to a `func(node: Node, tick: int,
previous: Dictionary) -> bool`: with the setting off, it is asked once such a
state changed the history and is merged, with the values this peer had recorded
for that tick before, which its own nodes met from then on. A state it answers
true for starts a resimulation from its tick, as with the setting on. Answer
from the poses at hand, e.g. whether the node's received or previous position is
within reach of the local avatar, given how far both can move since `tick`.
Unset, no such state starts a resimulation.

*Send newest state only* changes when rollback state is sent. Off, the
default, the state of every tick a rollback loop resimulates is sent, to each
peer that sees a node whose state changed at that tick, so a tick goes out
again each time a late input changes it. On, state is sent once per loop: each
peer gets, for each node it sees, the node's newest authoritative state - the
tick its owner's newest input simulated, which differs from node to node - if
it differs from the one it was last sent, all in one packet with a tick per
node. A diff state is then relative to the state last sent to that peer, and a
node is sent in full when the peer starts seeing it and with every full state
that finds a newer state of it - a node waiting for its owner's input, e.g. as
the owner disconnects, is sent nothing.
The server prepares and serializes one state per loop instead of one per
resimulated tick.

The owner of a node reconciles from its newest state either way. A peer that
only displays the node, e.g. interpolating between the states received, gets
fewer of them: a burst of ticks made authoritative in one loop arrives as its
newest only, and the ticks before it keep the previous state received. A peer
whose own nodes are simulated against the node's past ticks, e.g. in contact,
meets those ticks as held, not as simulated. Every peer must run with the same
value.

*Send intermediate states to others*, with *Send newest state only*, also sends
a peer that does not own one of a node's inputs every state of the node that
became authoritative since the one it was last sent, in the same packet. Such a
peer then holds every tick of the node, as without the setting, for its own
nodes to meet when they are resimulated, e.g. in contact; the input owner still
gets the newest state only.

*Debug resimulate ticks* makes every rollback loop resimulate at least this
many ticks, even when no new input or state arrived. A side effect that is not
safe to replay - a sound, a spawn, a counter outside of state - then happens
again in every loop, which makes it easy to spot. Leave it at zero outside of
testing.

*Enable diff states* toggles diff states. By sending only state properties that
have changed, netfox can reduce the bandwidth needed to synchronize the game
between peers. See [RollbackSynchronizer] on how this is done and configured.

[Client-Side Prediction and Server Reconciliation]: https://www.gabrielgambetta.com/client-side-prediction-server-reconciliation.html
[input prediction]: ../tutorials/predicting-input.md
[RollbackSynchronizer]: ../nodes/rollback-synchronizer.md
[NetworkPerformance]: ./network-performance.md
