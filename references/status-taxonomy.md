# status-taxonomy: session-tracker

## `status` (flat enum, lowercase)

| status | meaning |
|---|---|
| `active` | work in progress, recent activity |
| `dormant` | inactive but with open tasks -> the real "ghost" |
| `paused` | paused on purpose, waiting for an external event |
| `branched` | the work continued elsewhere (it generated forks/pilots that continue) |
| `done` | completed (terminal) |
| `dropped` | abandoned on purpose, will not be done (terminal) |
| `superseded` | replaced by another session/approach (terminal) |
| `unknown` | not analyzed yet |

- **Closed** = `{done, dropped, superseded}`.
- **Open item / at-risk** = everything else except `unknown`.
- No `:` in the values: direct jq filters on equality (`select(.status=="dormant")`).
- `branched` is NOT terminal: dormancy is computed normally, no special case in the merge. A fresh branched -> `low`; a branched gone stale with `open[]` still on it -> `high`, and it is right that it comes back in the dashboard as a loose end (either it comes back, or you close it as terminal). It is set with `stk branch` on the trunk (user override: `status_source=user`).

## `status_source`

`auto` (default, derived from the extraction) | `user` (manual override). The merge updates `status` from `proposed_status` ONLY if `status_source == auto`. A user override is recorded with a `status_change` event `by:"user"` and sets `status_source: user` (never overwritten afterwards).

## `dormancy_risk` (computed)

How likely a session is to be a "ghost" to recover. It is computed at merge:

- `high`: `last_activity_at` older than 30 days **AND** `open[]` not empty **AND** status not closed.
- `medium`: `last_activity_at` between 7 and 30 days, `open[]` not empty, status not closed.
- `low`: otherwise.

It is the primary signal for the query "what was left hanging?": sort the `dormant`/non-closed by `dormancy_risk` desc.

## Status inference (extraction guidelines)

- empty `open[]` + closure signals (final commit/PR, "done", "closed") -> `done`.
- explicit decision not to proceed -> `dropped`.
- the user says "let's redo it differently" / another session restarts on the theme -> `superseded` (or `branched` if it continues as a fork/pilot).
- open tasks + no closure signal -> `active` if recent, otherwise the merge brings it to `dormant` via `dormancy_risk`.
- when in doubt -> `unknown` (it will be reviewed at the next tick).
