# UX options

The interactive mockups (not published) opened with a working prototype of the chosen view mode switcher (List, Board, Table, inspector, Compact window, and search tokens), followed by the original options in four groups using the same fictional sample data. The decision is recorded at the bottom of this file.

## Group 1: Main window layout

| Option | Summary | Best for | Main trade-off | Build cost |
|---|---|---|---|---|
| **A. Triage inbox (recommended)** | Three panes: sources, list grouped by whose move it is, detail with actions | Working through the to-do list one PR at a time | Needs a wide window | Low to medium |
| B. Status board | Columns per actionable state | Overview of workload shape | Wide; detail is one click further | Medium |
| C. Repo table | Dense sortable table grouped by repo | Many repos, column scanning | Reads as a report, not a to-do list | Low |
| D. Compact focus list | Narrow column of action cards, shared with the popover | Small window beside the editor | Weak for browsing a whole repo | Low |

## Group 2: Menu bar

| Option | Summary | Main trade-off |
|---|---|---|
| M1. Native menu | Standard NSMenu with a submenu of actions per PR | No status chips or inline buttons |
| **M2. Rich popover (recommended)** | SwiftUI panel with chips, tabs, and one-click actions | Needs care with keyboard focus |
| M3. Hybrid | Left click popover, right click native menu for app controls | Hidden right-click behavior; needs `NSStatusItem` |

Icon states shown for all options: count, urgent dot (optional), all clear, paused, needs sign in.

## Group 3: Notification strategy

| Option | Summary | Main trade-off |
|---|---|---|
| N1. Every event | One banner and sound per event | Bursts on busy mornings |
| **N2. High urgency individually, rest summarized (recommended)** | Review requests and changes requested get their own banner; other events from the same sync are folded into one summary | CI failures are one click further unless promoted in Settings |
| N3. Summary only | One banner per sync with counts, optionally batched to set times | Slower response to review requests |

## Group 4: Jump to a repo or PR

| Option | Summary | Main trade-off |
|---|---|---|
| **Q1. Global floating switcher (recommended)** | Spotlight-style panel on a global shortcut; modifier keys choose the action (open, GitHub, Claude, terminal) | Needs a global hotkey that does not clash with other launchers |
| Q2. Search inside the main window | Toolbar search with filter tokens | Window must be brought forward first |

## Decision

Recorded 2026-10-13. The picks are the **defaults**. The other options in groups 1, 3, and 4 are kept as alternate modes the user can switch to (see below).

| Group | Default | Alternates kept | Alternates dropped |
|---|---|---|---|
| Main window | A. Triage inbox (List mode) | B as Board mode, C as Table mode, D as Compact window | None |
| Menu bar | M2. Rich popover | None in v1 | M1, M3 (see rationale) |
| Notifications | N2. High urgency individually, rest summarized | N1 and N3 as a notification style setting | None |
| Quick switcher | Q1. Global floating switcher | Q2 in-window search with filter tokens, available at the same time | None |

## View modes

### Scope and presentation are separate

The main window separates **what** you are looking at from **how** it is shown:

- **Scope** is chosen in the sidebar: Inbox, My PRs, Reviewing, Snoozed, or a single repo.
- **Presentation** is chosen in the toolbar with a segmented control: **List**, **Board**, or **Table**.

Any scope can be shown in any presentation. All three presentations render the same filtered, sorted PR set and share selection, filters, and search, so switching modes never loses your place.

| Mode | From option | Layout | Detail | Shortcut |
|---|---|---|---|---|
| List (default) | A | Sidebar, grouped list, detail pane | Detail pane, always visible | Control-Command-1 |
| Board | B | Sidebar (collapsible), columns per primary state | Inspector on the right, toggled | Control-Command-2 |
| Table | C | Sidebar, sortable table; group by repo, state, or none | Inspector on the right, toggled | Control-Command-3 |

Board columns (built 2026-10-13): Review requested, Changes & comments, CI failing, Conflicts & behind, Ready to merge, Waiting on others. All columns always show, so the board keeps its shape. Arrow keys move between cards and columns.

### Stacked PRs

A PR whose base branch is another open PR's head branch in the same repo is stacked on it. Fork PRs are never parents. In every presentation, stack members are kept together, parent first, indented, with an "on #N" marker; the detail pane shows the whole stack and warns when a ready-to-merge PR still has an open parent. Detection uses only tracked PRs and costs no API calls.

A stack can be collapsed into one row. The first row of each stack run (the stack members in one section, column, or table group) has a disclosure chevron; collapsed, the row reads "+N stacked" and the other members are folded into it. Collapse state is remembered per stack (by its root PR) and shared by List, Board, and Table. Right-click a row for Collapse Stack or Expand Stack, and use View > Collapse All Stacks or Expand All Stacks for every stack at once. Stacks start expanded.

Collapsing never moves a PR out of its section, so the Inbox's urgency order holds: a run sits where its most urgent member would sort, and a stack split across "Your move" and "Waiting on others" folds separately in each, so a child that needs you stays in "Your move" even when its parent is waiting. Section and column counts include folded PRs. Arrow keys on the Board skip folded cards. Grouping and folding live in `Stacks.fold` in ReviewCore.

Command-1 to Command-4 switch sidebar scopes (Inbox, My PRs, Reviewing, Snoozed). Option-Command-I toggles the inspector in Board and Table modes.

The app remembers a mode **per scope**. Example: Inbox in List, a busy repo in Table, My PRs in Board. A setting sets the default mode for new scopes.

### Compact window (option D)

Compact is a separate window mode, not a fourth presentation, because it changes the whole window rather than the content area:

- **View > Compact Window** (Shift-Command-M) or the "pop out" button in the menu bar popover opens a narrow, resizable window that shows the same card list as the popover.
- It can float above other windows ("Keep on top" toggle), which suits keeping it beside an editor.
- It reuses the popover's SwiftUI view, so it costs little to build.
- "Expand" in its toolbar opens the full main window at the same scope and selection.

### Notification style setting

Settings > Notifications > Style:

| Style | Behavior |
|---|---|
| Smart (default, N2) | High urgency events get their own banner; the rest from the same sync are summarized |
| Every event (N1) | One banner per event |
| Summary only (N3) | One summary banner per sync, with optional scheduled digests |

Per-event toggles and sounds apply under every style. Under Smart, each event type can be promoted to high urgency (for example, CI failures).

### Search

Both search styles ship. The global switcher (Q1) works from any app. Inside the main window, Command-F focuses the toolbar search, which accepts filter tokens (`repo:`, `author:`, `state:`, `label:`) and applies in every presentation mode.

### Why the alternate menu bar styles were dropped

- M1 (native menu) and M2 would be two full menu implementations to maintain. Switching them at runtime needs two `MenuBarExtra` scenes toggled with `isInserted`, which is doable but adds complexity for a small gain.
- M3 (right click for app controls) needs AppKit `NSStatusItem` instead of `MenuBarExtra`. The M2 popover footer already has the controls M3 offers (refresh, pause, open window, settings).

Revisit if the popover turns out to be slow or awkward from the keyboard.
