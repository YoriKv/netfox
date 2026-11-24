# NetworkPerformance

Provides [custom monitors] for measuring networking performance. Included as an
autoload.

## Enabling monitoring

By default, network performance monitoring is only enabled in debug builds and
when running from the editor.

Use the `netfox_noperf` feature tag to force disable network performance
monitors.

Use the `netfox_perf` feature tag to force enable network performance monitors.

These feature tags enable customization for each export preset.

## Performance monitors

### Network loop duration

*Network loop duration* measures the time spent in the [network tick loop].
Note that this includes time spent on the [rollback loop] as well.

This value is updated once for every tick loop, it is not reset to zero after
the loop has run. This means that you may get a non-zero reading, even if the
tick loop is currently not running.

### Rollback loop duration

*Rollback loop duration* measures the time spent in the last [rollback loop].
This includes all of its steps. 

The value of this monitor may be zero, if no players have joined, no nodes use
rollback, or rollback is disabled.

### Network ticks simulated

*Network ticks simulated* measures the number of ticks run in the last [network
tick loop]. If the game runs at a higher FPS than the network tickrate, this
value should be consistently one.

Higher, stable values mean that the game itself runs slower than the network
tickrate, and needs to catch up by running multiple ticks on each frame.

### Rollback ticks simulated

*Rollback ticks simulated* measures the number of rollback ticks run in the
last [rollback loop]. Generally, this denotes the age of the oldest input *or*
state received, depending on whether the game is running as a server or client.

The measurement is strongly correlated to network latency - the higher the
latency, the older the state and input packets will be upon arrival.

The more rollback ticks need to be simulated, the more work the rollback tick
has to do, which can negatively affect performance.

### Rollback tick duration

*Rollback tick duration* provides the average time spent simulating a single
tick in the last [rollback loop].

This can be useful to determine if the rollback tick duration comes from too
many ticks being simulated, or the individual ticks being expensive to
simulate ( or both ).

### Rollback nodes simulated

*Rollback nodes simulated* counts the node-ticks run in the last [rollback
loop]. Of those, *Rollback nodes simulated fresh* were run for the first time
for their tick, and *Rollback nodes simulated with new input* had input for
their tick that was received or recorded since the loop before. Node-ticks
outside both reran a tick with nothing new for that node.

### Corrections

*Corrections* counts the authoritative states received during the last tick
loop that differed from the state recorded for a node this peer simulates. See
[NetworkRollback] for the `on_correction` signal, which tells which properties
differed. `get_corrections_total()` returns the count since startup.

### Input lateness

*Input lateness mean* and *max* measure, on the receiving peer, how far behind
the current tick each accepted input tick was on arrival, over the last second.
Negative values mean the input arrived early. Inputs recovered from redundancy
count with their own tick. Per peer values are available with
`get_input_lateness_mean(peer)` and `get_input_lateness_max(peer)`.

### Inputs refused

*Inputs refused* counts the input ticks refused during the last tick loop for
falling outside of the accepted range, see [NetworkRollback]'s settings.
`get_inputs_refused_by(peer)` returns the total per peer.

### Sent bytes

*Sent rollback state bytes*, *Sent input bytes* and *Sent sync state bytes*
measure the data handed to [NetworkCommandServer] during the last tick loop,
without the transport's overhead. Each command also counts its own bytes, see
`Command.get_sent_bytes()`.

[NetworkRollback]: ./network-rollback.md
[NetworkCommandServer]: ./network-command-server.md
[custom monitors]: https://docs.godotengine.org/en/latest/classes/class_performance.html#class-performance-method-add-custom-monitor
[network tick loop]: ./network-time.md
[rollback loop]: ./network-rollback.md
