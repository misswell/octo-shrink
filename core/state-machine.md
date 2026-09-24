# Compression lifecycle protocol

This protocol applies to Direct and App Store builds (the same Tauri frontend and
Rust scheduler) and to the Swift native app. Implementations differ; behavior does not.

## State ownership

| Layer | Values | Owner |
| --- | --- | --- |
| Queue item | `pending`, `running`, `done`, `failed`, `restored`, `removed` | Tauri `queueItems`; Swift `AppState.items` |
| Execution session | `idle`, `running`, `paused`, `stopping` | Tauri scheduler and frontend mirror; Swift scheduler and `AppState` |
| Scheduler | Pause, stop, and parallelism gate | Rust or Swift scheduler |
| UI | Derived labels, controls, and queue progress | Frontend or SwiftUI |

`finished` is the instant a session settles, not a stored phase: the transition is
`running/paused/stopping → idle`. Queue items survive that transition. A session
captures pending target paths at start; later imports are for a later session.

## Transitions

| Action | Session | Queue items |
| --- | --- | --- |
| Start or continue | `idle → running`, new session ID | Snapshot only `pending` |
| Pause | `running → paused`, same session ID | Unstarted items remain `pending`; running items finish |
| Resume | `paused → running`, same session ID | No reset or resubmission |
| Stop | `running/paused → stopping → idle` | Running items finish; unstarted items remain `pending` |
| Explicit removal | No session change | Target becomes `removed`; cancellation wakes the gate without resuming it |
| Failure | No session change | `running → failed`; retry requires an explicit action |
| Explicit retry or recompress | New session when idle | Selected `failed`/`restored` item returns to `pending` |
| Restore original | No session change | `done → restored` only after disk and history restore succeed |
| Clear all | Current workers finish safely | Queue generation increments; old callbacks cannot modify new items |

The scheduler checks **cancel → stop → pause/parallelism**. Stop emits `deferred`
for unstarted work, never `cancelled`. Only explicit removal emits `cancelled`.
Automatic compression may open another session for newly imported pending items
after normal completion. Explicit stop suppresses that automatic continuation.

## Progress and controls

`total = pending + running + done + failed`; `processed = done + failed`.
`removed` and `restored` do not count. The user sees `processed / total` from the
whole queue, including after stop and continue. Session counts are diagnostic only.
The main button derives its label from phase and queue: running, paused, and
stopping show their phase; idle with pending shows start or continue; idle with
no pending shows completion and any failure count. The pause icon is static.

## Event envelope

Tauri `compress-progress` events use camelCase fields:

```json
{
  "sessionId": "session-1-1720000000000",
  "queueRevision": 0,
  "file": "/path/to/image.png",
  "status": "starting",
  "timestamp": 1720000000000
}
```

`status` is one of `queued`, `starting`, `completed`, `failed`, `cancelled`,
`deferred`. Completion and failure also carry `result`; events may carry
`sessionTotal` and `sessionProcessed` for diagnostics. Consumers reject events
whose session ID or queue revision differs from the active snapshot, and events
for paths outside that snapshot. The frontend also checks the queue item's
object identity. Swift callbacks carry the same session ID and queue revision
internally, plus the queue item's UUID. A reimported path is never mistaken for
its old item. Neither UI uses a DOM class or button text as
business state.
