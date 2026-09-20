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
- **A planner that thinks** - the assistant layer goes well beyond a to-do list:
  - **Day at a glance** - a reasoned, time-blocked plan for today (renders
    instantly from your data, then an LLM refines it in the background).
  - **Ask Orbit** - an agentic Q&A that *calls tools to read your real agenda*
    (byLLM ReAct tool-calling) before answering "what should I do first?".
  - **Weekly overview** - an AI outlook with the busiest day, risks, and a
    concrete suggestion.
  - **Proactive suggestions**, **natural-language capture**, and **one-tap
    task breakdown**.
  - Every AI feature has a deterministic fallback, so Orbit works fully with
    **no model and no API key**.
- **Live connectors** - pull real items from **Google Calendar** and **Notion**
  into the one unified stream. Credentials live in a gitignored `.env`.
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
- **AI is on by default and self-configuring.** Copy `.env.example` to `.env`:
  - **Default (no key):** Orbit uses the **bundled local model (Qwen)** - fully
    offline, no key required. It runs the day plan, chat, weekly overview, and
    capture on your machine. (Its CPU backend is slower than the cloud and can
    be unstable on some hardware.)
  - **Recommended for a demo:** set `ANTHROPIC_API_KEY` to route to **Anthropic
    Claude** - faster and more reliable than the local model.
  - **Deterministic-only:** set `ORBIT_AI_OFF=1` to skip the model entirely and
    use Orbit's deterministic logic - every AI feature has a fallback, so the
    app is fully functional either way and never breaks.

  The local model needs a one-time install (bundled with the `byllm[local]`
  dependency; pull the weights with `jac model pull qwen3.5-4b`). Orbit also
  caps every prompt it sends the model.

---

## Run the web app (and server)

From the repository root:

```bash
jac run
```

Open **http://localhost:8000** (the first run installs dependencies, so give it
a moment). **On first run the graph is empty - you do not need to connect
anything to start.** Type a task into the capture bar at the top (e.g. "read the
FlashAttention paper by Friday") and Orbit files it, or connect Google Calendar
and Notion (see below) and click **Sync now** to pull in your real schedule.

The web app's tabs:

- **Briefing** - today's plan, this week, slipping, and overload flags.
- **Chat** - ask Orbit about your week, your deadlines, or what to do first.
- **Agenda** - every item, add/complete/delete, filterable by area.
- **Insight** - streaks, completion, area load, and the deadline density chart.
- **Settings** - connectors, plus add/rename/archive areas at runtime.

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
jac run cli ask "what should I do first today?"   # the AI assistant, in your terminal
jac run cli sync                  # pull from configured connectors
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

Then, with the backend running (`jac run` in another terminal), start the
mobile app in the browser via react-native-web - no Android SDK or Xcode
needed:

```bash
jac run --platform web mobile --dev
```

This is the simplest way to see the mobile app. Running it on a real device or
emulator needs the platform toolchains:

```bash
jac run --platform android mobile   # needs Android SDK + emulator/device
jac run --platform ios mobile       # needs Xcode (macOS)
```

The mobile app is a full port of the web experience - the same five tabs
(Briefing, Chat, Agenda, Insight, Settings), the same warm theme, and a fixed
bottom tab bar - rebuilt in React Native primitives against the same backend as
the web and CLI.

---

## Use the desktop app (bonus)

The desktop app wraps the web UI in a native OS window:

```bash
jac run desktop
```

It embeds a webview over the same served client and backend, so it is the exact
web experience as a desktop application.

---

## Connect your Calendar and Notion (optional)

Orbit can pull real items from external services into the one unified stream.
Both are optional and read their credentials from `.env` (gitignored); with
none configured the app runs exactly as above. Copy `.env.example` to `.env`,
fill in any subset, and click **Sync now** in Settings (or run `jac run cli sync`).

- **Google Calendar** - in Calendar settings, copy the calendar's *"Secret
  address in iCal format"* and set `ORBIT_CAL_ICS_URL`. No OAuth needed.
- **Notion** - create an internal integration at
  [notion.so/my-integrations](https://www.notion.so/my-integrations), share your
  to-do database with it, and set `NOTION_TOKEN` + `NOTION_DB_ID` (plus the
  property names if they differ from `Name` / `Due`).

Re-syncing updates imported items in place (keyed by source + external id)
rather than duplicating them.

---

## How the components fit together, and what makes it impressive

All four surfaces are thin clients over **one shared core** (`core/orbit/`):

- `model.jac` - the node/edge/enum data model and response types.
- `items.jac`, `areas.jac` - the item and runtime-area endpoints.
- `scoring.jac`, `briefing.jac` - the deterministic urgency score and Briefing.
- `analytics.jac` - the Insight metrics.
- `config.jac`, `llm.jac` - secrets/`.env` loading and the auto-selected model.
- `ai.jac` - capture, narration, and breakdown (`by llm`, with fallbacks).
- `assistant.jac` - day-at-a-glance, weekly overview, suggestions, and the
  agentic `ask` (byLLM tool-calling over the graph).
- `connectors.jac` - the Google Calendar / Notion ingestion.

The **web app** and its server come up with a single `jac run`. The **CLI** and
**mobile** and **desktop** apps all reach the same endpoints, so the planning
data and logic are shared, not duplicated.

What makes Orbit stand out:

- **Depth over breadth.** Rather than six shallow trackers, one item model plus
  one genuinely useful Briefing - urgency scoring, overload detection, and a
  slipping list - is the centerpiece.
- **Runtime-extensible.** Areas are data, not code; you shape the app to your
  life without touching a source file.
- **Genuinely agentic AI.** "Ask Orbit" uses byLLM ReAct **tool-calling** to
  read your real items before answering, and the day plan is reasoned, not
  templated - yet every feature degrades to deterministic logic with no model,
  so the app never breaks.
- **Real integrations, done natively in Jac.** Google Calendar and Notion are
  pulled in through Jac's Python interop, with secrets kept in a gitignored
  `.env`.
- **One backend, four (five) surfaces** that actually work together: capture on
  the CLI, plan on the web, triage on mobile, all live.

---

## Development

```bash
jac check <file>                   # type-check and lint
jac test                           # run the core test suite (pure-logic + graph tests)
jac build mobile --platform web    # bundle the mobile app for the browser
```

The core logic lives in `core/orbit/`; the surfaces are in `web/`, `mobile/`,
`cli/`, and `desktop/`.
