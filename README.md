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
- **Grouped by topic** - items about the same course, project, or company collapse into one row, like `Chem 101 | Lab | Quiz`.
  The model decides what belongs together; nothing is hardcoded.
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
  The week board joins each day's items on one topic into a single row (`Chem 101 | Lab | Quiz`).
- **Chat** - ask Orbit about your week, your deadlines, or what to do first.
- **Agenda** - every item, add/complete/delete, filterable by area.
  Items on one topic share a card (`Sessions · Sep 28, Oct 2–4 | Lab · Sep 29–Oct 1`); the count on the right opens the individual items.
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

> **Platform note:** the desktop target's native build backend is currently
> **Linux-only** - it assembles the native window from GTK3 + WebKitGTK, so
> `jac run desktop` only builds on a Linux host. On macOS or Windows it exits
> with `The current desktop native build backend supports Linux hosts, not
> <host>`. To try it from macOS/Windows, build it inside a Linux VM or
> container. Because the desktop app just wraps the same served client, running
> the web app (`jac run`) shows the identical UI.

---

## Connect your Calendar and Notion (optional)

Orbit can pull real items from external services into the one unified stream.
Both are optional and read their credentials from `.env` (gitignored); with
none configured the app runs exactly as above. Copy `.env.example` to `.env`,
fill in any subset, and click **Sync now** in Settings (or run `jac run cli sync`).

- **Google Calendar** - in Calendar settings, copy the calendar's *"Secret
  address in iCal format"* and set `ORBIT_CAL_ICS_URL` (read-only, no OAuth
  needed). Its events are filed by title (see *How imports are filed* below),
  or all go to one area with `ORBIT_CAL_AREA`.
  - **Multiple calendars:** import several color-coded feeds with
    `ORBIT_CAL_ICS_URLS` - a list of `area|url` pairs separated by `;`, e.g.
    `research|https://…;fitness|https://…`, so each Google calendar maps to its
    own Orbit area. Use the area `auto` to file each event by its title
    (e.g. `auto|https://…`). The two variables **combine**: set either, or
    both (a single feed via `ORBIT_CAL_ICS_URL` plus a set via
    `ORBIT_CAL_ICS_URLS`), and all feeds are pulled.
- **Notion** - create an internal integration at
  [notion.so/my-integrations](https://www.notion.so/my-integrations), copy its
  secret to `NOTION_TOKEN`, and share the page or database with it. Orbit reads
  from **either** source:
  - **A database** - set `NOTION_DB_ID`. Each row becomes an item. Its title,
    date, and done columns (a checkbox or a status) are found by type, so any
    database works; pin them by name with `ORBIT_NOTION_TITLE_PROP` /
    `ORBIT_NOTION_DATE_PROP` if needed.
  - **A planning page** - set `NOTION_PAGE_ID` instead, and Orbit reads the
    page's structure (nested blocks included):
    - To-do checkboxes under a weekday heading (`Monday` ... `Sunday`, e.g. a
      column per day) become that day's work sessions in the current week;
      other to-dos become undated tasks. A checked box marks the item done.
    - Every other line is read for to-dos, in whatever form it takes. With a
      hosted model, the model reads each line whole - `Errands: pharmacy,
      bank, and call the landlord` becomes three tasks - and its answer is
      checked against the line: a title whose words are not in the line is
      dropped, and only date words copied from the line become the due date
      (parsed in code, never computed by the model).
    - With the small local model, which misreads about 40% of lines read that
      way, the line's explicit structure is split in code instead: `Project:
      task one 9/24 5:30pm | task two (paused until Oct 2); task three` becomes
      one task per `|` or `;` part, titled with the project. Dates and clock
      times become the due, and status such as `(paused ...)` or `- done, one
      chore left` moves to the notes. The model judges only each line's shape -
      separate tasks, one task whose parts are its subtasks (a study list), or
      not a to-do at all (a motto, a watch list).
    - Either way the model's verdicts are cached, so only new or edited lines
      are re-read. A note that restates a calendar event (same day, same name
      within an hour) is dropped in favour of the calendar's copy.
  - If both are set, `NOTION_PAGE_ID` takes precedence. Imported items are
    filed by title, or all go to one area with `ORBIT_NOTION_AREA`.

### How imports are filed

Nothing in the code knows anyone's labs, companies, or courses. Each area in
**Settings** has a hint - your note on what belongs there ("AIMS lab: papers,
experiments", "IA for EECS 491: office hours, Piazza"); built-in areas start
with a generic one. Each new title is filed by, in order:

1. **Your own words** - a title you filed yourself, or a name in exactly one
   area's hint (a course code, an acronym, a capitalized name like
   `Old Mission`).
2. **The model** - it reads your areas and hints, plus the items you filed
   yourself that look most like the title. Its verdict is cached per title, and
   editing any hint re-files everything on the next sync.
3. **Without AI** - the same words, matched in code.

Imported items follow the source on every sync, including their area, unless
you moved one to another area by hand.

Recurring calendar events are expanded into one item per occurrence (with
exceptions, edited occurrences, and cancellations applied).

Re-syncing updates imported items in place (keyed by source + external id)
rather than duplicating them, and removes open items the source no longer has
(a cancelled event, an edited or split note). Completed items are kept.

---

## How items are grouped by topic

Nothing in the code knows which of your items belong together, and nothing about how you write titles is hardcoded - a topic can sit anywhere in a title and be set off by any punctuation, or none.
Code only proposes candidates: runs of words that several titles share anywhere (`Chem`, `Chem 101`), and runs spelled almost the same way.
The model then answers one small question per candidate.
Do `Chem 101` and `Chem 240` belong to the same thing? No, so `Chem` is too broad.
Do `Chem 101` and `Lab for Chem 101`? Yes, so `Chem 101` is a topic and `Lab for` is that item's part.
Is `Chme 101` a typo of `Chem 101`?
A single shared word that is not at the start of every title it appears in must also pass a second question: is `Meeting` the name of one specific thing, or a general word?
Asked pairwise, a small model calls `Chem 101 - Staff Meeting` and `Book club - Meeting` the same group; asked about `Meeting` itself, it says general.
A small local model answers such narrow questions far more reliably than "is this whole list one subject?".
Each verdict is voted, cached in the graph, and asked a few at a time, so the first pass refines the view without holding up the app, and later loads are instant.
Without AI, a title that is exactly the shared words (`Chem 101` for `Chem 101 Lab`) or shared leading words set off by punctuation (`Recruiting: ...`) still groups.

On the week board, clicking a row's checkbox completes the whole group, and clicking one part completes just that item.
On the Agenda, clicking a part completes its next open item, so one click finishes today's session rather than the whole week.

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
- `topics.jac` - which items share a topic, judged by the model and cached, for the grouped week board and agenda.

The web and mobile apps also share `lib/dates.jac` for date labels such as `Sep 28, Oct 2–4`.

The **web app** and its server come up with a single `jac run`. The **CLI** and
**mobile** and **desktop** apps all reach the same endpoints, so the planning
data and logic are shared, not duplicated.

What makes Orbit stand out:

- **Depth over breadth.** Rather than six shallow trackers, one item model plus
  one genuinely useful Briefing - urgency scoring, overload detection, and a
  slipping list - is the centerpiece.
- **Runtime-extensible.** Areas are data, not code; you shape the app to your
  life without touching a source file.
- **Grouping without hardcoding.** Related items collapse into one row per topic, and the code knows nothing about your courses or how you write titles.
  A small local model makes every call through narrow, cached questions it answers reliably.
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
