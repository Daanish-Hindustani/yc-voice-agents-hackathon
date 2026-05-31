# Google Calendar (web) skill

> **Audience.** Skill for the agent driving Google Calendar at
> `https://calendar.google.com`. This is a how-to-use-the-app
> guide: what the buttons do, where they are, and what the common
> user requests translate to in clicks and keystrokes. Engine-
> level quirks (which button needs a pixel click, which AX action
> works) are in the system prompt rules — this file describes the
> application itself.

## Layout

The page has four regions:

- **Top bar** (header, full width). Hamburger menu → "Today"
  button → date arrows → current-period label → search → settings
  → view switcher (Day / Week / Month / Year / Schedule) →
  Google account avatar.
- **Left rail** (~256 px wide). The red "Create" button at top,
  then a mini-month calendar, then "Search for people", then "My
  calendars" and "Other calendars" lists.
- **Main grid** (everything else). The calendar view itself. In
  Week view, columns are days and rows are hours. In Month view,
  rows are weeks and cells are days. Events appear as colored
  tiles inside cells.
- **Right rail** (collapsible, hidden by default on narrow
  windows). Side-panel apps (Keep, Tasks, Contacts). Ignore
  unless the user asks for one of them.

## How to do common things

### Create an event

1. Click the **"Create"** button in the top-left of the left rail.
   A small menu drops down — click **"Event"**.
2. The event-creation panel opens. It's a popover anchored to the
   Create button (or to wherever you clicked if you used the grid
   path below).
3. Fill in fields top-to-bottom:
   - **Title** — text input at the top. Just type.
   - **Start date / Start time** — two side-by-side buttons. Each
     opens a popover picker when clicked.
   - **End date / End time** — same.
   - **Add description or attachments** — optional.
   - **Add guests** — optional email field.
   - **Add location** — optional text field.
4. Click **"Save"** in the top-right of the panel. Calendar
   confirms with a snackbar at the bottom.

**Faster path for a specific time slot:** click an empty cell in
the grid at the time you want. The event panel opens pre-filled
with that day and a 1-hour slot starting at the clicked time.
Saves you four clicks if you know the date.

### Change a date or time

The date and time fields are buttons that open pickers, not text
inputs. Clicking opens a popover:

- **Date picker** — a mini-month grid. Click the day you want, or
  use the arrows to change month. Today is highlighted.
- **Time picker** — a vertical list of 30-minute slots. Scroll to
  find the one you want, click it.

You can also **type into the date/time button after clicking**
once the popover is open. Calendar parses `May 18, 2026` and
`7:00pm` reliably. Then press Tab or click out to commit.

### Invite people

1. With the event panel open, click **"Add guests"**.
2. Type the email address. Calendar autocompletes against your
   contacts after 2–3 characters; click the suggestion or press
   Return when the right one is highlighted.
3. Repeat for additional guests.
4. Save. Calendar shows a confirmation dialog asking whether to
   send invitation emails — click **"Send"** to notify guests or
   **"Don't send"** to add silently.

### Read what's on the calendar

The grid already shows event titles. For more detail:

- **Hover** a tile to see a tooltip with title + time.
- **Click** a tile to open the event detail popover (title,
  time, description, guests, location).
- For a programmatic dump of everything visible, use the `page`
  tool's `get_text` action on the main grid — Calendar renders
  visible event titles into the DOM as plain text.

### Edit an existing event

1. Click the event tile in the grid.
2. The detail popover opens. Click the **pencil icon** to open
   the full edit view (or just edit fields directly in the
   popover for quick changes).
3. Change what you need.
4. Click **"Save"**. If it's a recurring event, Calendar asks
   whether to apply the change to "This event", "This and
   following events", or "All events".

### Delete an event

1. Click the event tile.
2. Click the **trash icon** in the detail popover toolbar.
3. For recurring events, Calendar asks the same scope question.

### Navigate to a specific date

- **Today** — click the "Today" button in the top bar.
- **Forward / back one week (or month, depending on view)** —
  the `<` and `>` arrows next to the period label.
- **Jump to an arbitrary date** — click any day in the
  mini-calendar in the left rail. Or change the URL directly:
  `https://calendar.google.com/calendar/u/0/r/day/2026/5/18`
  for Day view on May 18 2026. View segments: `day`, `week`,
  `month`, `year`, `agenda` (Schedule view).

### Switch views

In the top-right corner there's a dropdown labeled with the
current view (Day / Week / Month / Year / Schedule / 4 days).
Click it and pick the one you want. Keyboard shortcuts also
work: `d` = Day, `w` = Week, `m` = Month, `y` = Year, `a` =
Agenda. These shortcuts only fire when no input field is
focused.

### Search

Click the magnifying glass in the top bar. A search input
expands. Type a query (title, guest name, location, etc.) and
press Return. Results appear in a list with date + time + title.
Click a result to jump to that event.

## How to refer to dates

Calendar's date fields parse:

- `May 18, 2026` — fully qualified, always works.
- `5/18/2026` — works.
- `Tomorrow`, `Next Monday` — does **not** work in the input
  field. These are user-facing phrases, not parsed strings.
  Always convert relative phrases to absolute dates before
  typing.

Today's date is in the system prompt prelude — use it to resolve
"tomorrow", "tonight", "next Friday".

## How to refer to times

The time picker accepts:

- `7:00pm` / `7 PM` / `19:00` — all work.
- `7pm` — works.
- `7` alone — ambiguous; picker may guess 7 AM. Prefer a fuller
  form.

## Account context

Calendar opens in whichever Google account is the default in the
current Chrome profile. If the user has multiple accounts signed
in and asks you to use a specific one, navigate to
`https://calendar.google.com/calendar/u/<n>/r` where `<n>` is the
account index (0, 1, 2, ...). The account chooser is reachable
via the avatar in the top-right if you need to confirm which
account you're in.

## Keyboard shortcuts (worth knowing)

- `c` — create event
- `e` — view event details (when one is focused)
- `Backspace` / `Delete` — delete focused event
- `t` — jump to today
- `g` — go to date (opens a date input)
- `/` — focus search
- `?` — show shortcuts help

These only fire when no input is focused. They're often faster
than clicking through the UI for simple operations:
"create event tomorrow at 7pm" can be `c` → fill panel → Save,
which is one fewer click than the Create-button path.

## What not to do

- Don't open new tabs to do parallel work. One agent window =
  one tab; opening more makes `page` tool calls ambiguous.
- Don't click the left-rail "My calendars" or "Other calendars"
  section headers thinking they're event creators — they just
  collapse / expand calendar lists.
- Don't try to schedule across multiple calendars in one event
  unless the user explicitly asks. Default to the user's primary
  calendar.
- Don't send invitations to guests without explicit user intent.
  When the "Send invitations?" dialog appears, default to
  "Don't send" if the user only said "schedule" or "create" —
  ask if you're not sure.
