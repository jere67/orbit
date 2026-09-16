# Orbit - the agenda that thinks

**Author:** Jeremy Moon
**UMID:** 30448996
**Course:** EECS 449 - Assignment 1 (Personal Planning App in Jac)

Orbit is a single agenda for a busy student's whole life - research, job hunt,
coursework, TAing, clubs, fitness, and anything else - that does not just list
what you have to do, but tells you **what to care about right now**.

Instead of six separate trackers, everything is one kind of item tagged by a
runtime-defined *area*. On top of that one stream sits the **Briefing**: a
prioritized, cross-cutting view that answers "what's due today, what's slipping,
and what's coming up?" - with an optional AI voice narrating it.

The same backend powers four surfaces (plus a bonus fifth): a **web app**, a
**mobile app**, a **CLI**, and a **desktop app**, all sharing one data store.

---

## Main features

- **The Briefing** - a prioritized "what matters now" view built from a real
  urgency score (due-date pressure + priority + effort), with automatic
  **overload flags** ("Thursday looks heavy: 4h across 3 items") and a
  **Slipping** list of overdue items.
- **One unified stream** - research, jobs, coursework, TA, clubs, fitness, and
  any area you invent are all just items in one graph, filtered and color-coded.
- **Runtime-addable areas** - create, rename, or archive areas from the web
  Settings panel, the CLI, or an AI capture. No code changes, ever.
- **AI assistance (optional, graceful)** - natural-language capture ("read the
  paper by friday"), an AI-narrated daily briefing, and one-tap task breakdown.
  Every AI feature falls back to deterministic logic, so Orbit works fully with
  **no model and no API key**.
- **Insight analytics** - per-area load, completion rate, a 14-day deadline
  density chart, and completion streaks, all derived from your activity.
- **Four surfaces, one backend** - capture from the terminal, plan on the web,
  triage on your phone, all against the same live data.

---

## Prerequisites

- **Jac 0.37.12** (`jac --version`). Install via the
  [one-line installer](https://www.jaseci.org/) if needed.
- That's it for the web, CLI, and desktop apps - the Jac binary bundles the
  server, client toolchain, and byLLM.
- **Mobile** additionally needs the React Native / Expo toolchain, which
  `jac setup mobile` installs for you (Node is bundled by Jac).
- **AI features are optional.** They are off-path by default and degrade
  gracefully. To enable the bundled local model (no API key, no cost):

  ```bash
  jac install 'byllm[local]'
  jac model pull gemma-4-e4b
  ```

  The model is configured in `jac.toml` under `[byllm.model]`. To use a stronger
  cloud model instead, set `default_model = "anthropic/claude-sonnet-5"` there
  and `export ANTHROPIC_API_KEY=...` before running.

---

## Run the web app (and server)

From the repository root:

```bash
jac run
```

Open **http://localhost:8000**. On first run the graph is empty - open the
**Agenda** tab and click **"Load a sample week"** to populate a realistic demo,
or just start capturing your own items in the bar at the top.

The four tabs:

- **Briefing** - today, this week, slipping, and overload flags.
- **Agenda** - every item, add/complete/delete, filterable by area.
- **Insight** - streaks, completion, area load, and the deadline density chart.
- **Settings** - add, rename, and archive areas at runtime.

---

## Use the CLI

With the server running (`jac run`), from another terminal:

```bash
jac run cli today                 # the briefing + today's items
jac run cli week                  # the week ahead, grouped by day
jac run cli list --area research  # all items, optionally filtered by area
jac run cli add "Email advisor about the draft" --area research --priority HIGH --due 2026-09-20
jac run cli capture "gym tomorrow and read the paper by friday"
jac run cli done b0047d9a         # complete an item by its id prefix (shown in `list`)
jac run cli area list             # list areas
jac run cli area add "Thesis"     # add a new area at runtime
```

The CLI is a real client of the running server - it calls the same HTTP
endpoints the web app uses, so anything you add from the terminal shows up in
the web app (refresh) and vice versa. Point it at a different server with
`ORBIT_URL=http://host:port/api/web/function`.

`add` options: `--area`, `--due YYYY-MM-DD`, `--priority LOW|MED|HIGH|CRITICAL`,
`--kind TASK|DEADLINE|EVENT|SESSION`, `--effort <minutes>`.

---

## Use the mobile app

First-time setup (installs the React Native / Expo scaffold):

```bash
jac setup mobile
```

Then run the dev server (keep `jac run` running in another terminal for the
backend):

```bash
jac run --dev mobile
```

Metro/Expo starts and prints a QR code and URLs. Press **`w`** to open the web
preview, **`a`** for an Android emulator, or scan the QR with the Expo Go app on
a physical device. You can also produce a standalone build:

```bash
jac build mobile --platform web      # browser bundle
jac build mobile --platform android  # needs Android SDK
jac build mobile --platform ios      # needs Xcode
```

The mobile app is a focused triage surface: read the AI briefing, complete
today's items with a tap, and quick-capture new ones - all against the same
backend as the web and CLI.

---

## Use the desktop app (bonus)

The desktop app wraps the web UI in a native OS window:

```bash
jac run desktop
```

It embeds a webview over the same served client and backend, so it is the exact
web experience as a desktop application.

---

## How the components fit together, and what makes it impressive

All four surfaces are thin clients over **one shared core** (`core/orbit/`):

- `model.jac` - the node/edge/enum data model and response types.
- `items.jac`, `areas.jac` - the item and runtime-area endpoints.
- `scoring.jac`, `briefing.jac` - the deterministic urgency score and Briefing.
- `analytics.jac` - the Insight metrics.
- `ai.jac` - the `by llm()` features, each wrapped with a deterministic fallback.

The **web app** and its server come up with a single `jac run`. The **CLI** and
**mobile** and **desktop** apps all reach the same endpoints, so the planning
data and logic are shared, not duplicated.

What makes Orbit stand out:

- **Depth over breadth.** Rather than six shallow trackers, one item model plus
  one genuinely useful Briefing - urgency scoring, overload detection, and a
  slipping list - is the centerpiece.
- **Runtime-extensible.** Areas are data, not code; you shape the app to your
  life without touching a source file.
- **Reliable AI.** The JARVIS-style features are real, but they never break the
  app - every one degrades to deterministic logic when no model is present.
- **One backend, four (five) surfaces** that actually work together: capture on
  the CLI, plan on the web, triage on mobile, all live.

---

## Development

```bash
jac check        # type-check and lint every app
jac test         # run the core test suite (pure-logic + graph tests)
jac run --show   # show the resolved run plan for each app
```

The core logic lives in `core/orbit/`; the surfaces are in `web/`, `mobile/`,
`cli/`, and `desktop/`.
