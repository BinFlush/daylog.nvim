# Integrations & the source contract

How `daylog.nvim` pulls work items from an external tracker (Azure DevOps today; Jira /
GitHub / Linear / your own next), and the contract a source implements. This doc is both the
**source-author reference** and the **design record** — why the contract looks the way it
does, including the assumptions a cross-tracker API review disproved.

See also `docs/architecture.md` (the overall pure-core / thin-shell design) and
`:help daylog-sources` / `:help daylog-custom-source`.

## The model in one line

**Sources fetch; the core ranks.** A source returns *your relevant work* as a flat list of
items; daylog caches it on disk, fuzzy-filters it client-side at pick time, and (the design
goal) ranks it by your own worklog. The network is quarantined to a periodic sync, so picking
is offline and instant.

## The contract

A source is a plain table that never touches the Neovim API:

```
{ fetch, format_item, format_items?, to_entry_text, search? }
```

- `fetch(cb)` — async; `cb(items, err)`. Produces the default item set (see *Fetch
  conventions*).
- `format_item(item) -> string` — the picker line for one item.
- `format_items(items) -> string[]` *(optional)* — aligned lines for the whole list (use
  `daylog.sources.picker.align`); falls back to `format_item` per item.
- `to_entry_text(item) -> string` — the activity text inserted after `HH:MM `; daylog
  sanitizes it, so a title can't inject trailing metadata.
- `search(query, cb)` *(optional)* — live whole-tracker search as you type (Telescope only).
  Omit it for a purely-offline, cache-only picker — which is the recommended default.

### Item shape (`DaylogItem`)

| field | req | meaning |
|---|---|---|
| `id` | ✓ | Stable id. The cache-dedup key **and** the worklog-ranking key. |
| `title` | ✓ | Display + the seed for `to_entry_text`. |
| `type?` | | e.g. `Bug`/`Task`/`Story`. Some trackers (GitHub, Linear) have none. |
| `state?` | | Raw status name — display only. |
| `active?` | | Normalized **open/working** (NOT done/closed/cancelled). Derive it from the tracker's status *category* so the core ranks/filters without knowing custom workflow names. |
| `updated?` | | ISO-8601 last-updated. A generic recency signal; lexically orderable. |
| `url?` | | Link in the tracker. |

`id`/`title` are required; the rest optional, so a toy source can return just `{id, title}`.
The core only *consumes* `id`, `active`, and `updated` (for caching and ranking); `type` /
`state` / `url` are for display. A source MAY also carry **its own domain fields** for its
`format_item`/template — e.g. the Azure DevOps source adds `project`.

### Fetch conventions (the part that makes it good)

A `fetch` should return **your relevant work**, defined the same way on every tracker:

1. **Involves me** — the broadest reasonable "mine": assigned **or** created **or** mentioned
   **or** watching, as far as the API allows. (Model: GitHub's `involves:@me`.) Not just
   *assigned* — people routinely work items assigned to someone else.
2. **Active** — exclude done/closed/cancelled, via the tracker's status *category* (robust to
   custom workflow names), not hardcoded status strings.
3. **Recently updated** — a rolling window (e.g. last 30 days), ordered updated-desc, capped
   to a sane N.
4. **Container-optional** — query org-wide / across projects where the API supports it; never
   *require* a container for scope.

**Scope overrides are the source's own config, not a generic knob.** Let users replace the
default scope with whatever their tracker speaks — a WIQL/JQL string, a saved-query id, a
search string, a GraphQL filter. See *Why* below for the cross-tracker reason this isn't
standardized.

## Why the contract looks like this (the API review)

We reviewed four trackers against the dimensions our two decisions ("what to pull" / "how to
order") hinge on. It validated the architecture but **killed two assumptions** that would
otherwise have become a public breaking change.

| | Azure DevOps | Jira | GitHub | Linear |
|---|---|---|---|---|
| Query form | WIQL (string) | JQL (string) | search syntax (string) | **GraphQL filter objects — no string** |
| Saved query by id | ✓ | ✓ (`filter=<id>`) | ✗ (UI only) | ✗ (views, UI only) |
| "Involves me" | assigned/created/mentioned | assignee/reporter/creator/watcher/commenter | `involves:@me` | **assigned + created only** |
| Active (normalized) | StateCategory | `statusCategory` | open/closed only | state `type` enum |
| Recency | `@Today-30` | `-30d` | **absolute date only** | `-P30D` (ISO duration) |
| Cross-container / org-wide | ✓ | ✓ | ✓ (global) | ✓ (viewer / all teams) |
| `type` | ✓ | ✓ | ✗ (issue vs PR) | ✗ (labels only) |
| `url` | returned | **construct** | returned | returned |
| Caps / limits | (200, ours) | paginate (`maxResults`) | **1000 results + 30/min** | complexity budget |

Reference queries:
- Jira: `GET /rest/api/3/search?jql=(assignee = currentUser() OR reporter = currentUser()) AND statusCategory != Done AND updated >= -30d ORDER BY updated DESC` — one call; `url` is constructed as `https://<domain>.atlassian.net/browse/<key>`.
- GitHub: `GET /search/issues?q=involves:@me is:open&sort=updated&order=desc` — global, one call; mind the 1000-result cap, 30 req/min, and **absolute dates only** (compute `now - Nd` yourself).
- Linear (GraphQL): `viewer { assignedIssues(filter: { state: { type: { in: ["unstarted","started"] } }, updatedAt: { gt: "-P30D" } }, orderBy: updatedAt) { nodes { identifier title state { type } updatedAt url } } }`.

### Decisions, and the rejected "universals"

- **Default scope = "involves me", not "assigned to me".** GitHub's `involves:@me` is the
  model; it catches the unassigned-but-worked items and generalizes (each source maps it to
  its closest net — Linear's caps at assigned+created).
- **Container optional everywhere.** All four support org-wide queries, so this is a general
  capability, not an ADO patch.
- **The core ranks by your worklog.** Frecency keyed on the universal `id` needs zero source
  cooperation and is the one truly cross-source relevance signal — so it lives in the core,
  not in any source.
- **Offline-first, reinforced by the APIs themselves.** GitHub's 1000+30/min, Jira's
  pagination, Linear's complexity budget — none want a per-keystroke live search. Sync
  periodically; rank locally; make `search` opt-in.
- **REJECTED: a generic `query` string knob.** Linear (and GitHub's GraphQL) have no string
  DSL — only structured filter objects. A cross-source query string is a false universal.
- **REJECTED: a generic `saved_query` id knob.** Only ADO and Jira expose one; GitHub and
  Linear don't. So scope-override stays each source's own business.

The contract therefore standardizes the **concept** (involves-me / active / recent,
container-optional) and the **item shape**, never the query mechanism.

## Roadmap

- [x] **Lock the contract** — item shape (`active`, `updated`), fetch conventions, this record.
- [x] **Core worklog-frecency ranker** — `lua/daylog/sources/rank.lua` (pure) scores the cached
  set by a **time-decayed frecency** over your recent daylogs: per logged entry, `base + minutes`
  discounted by `0.5 ^ (age / half_life)`, summed per item — folding recency, frequency, and time
  tracked into one number (Mozilla-frecency / recsys time-decay). Matched by
  `sanitize_text(to_entry_text(item))` against the last `frecency_days` of `.day` files (a live
  daybook scan in `pick.lua` — no hidden state); never-logged items fall back to `active` /
  `updated`. Config `picker = { rank?, frecency_days?, half_life_days?, base? }`; `rank` overrides
  wholesale. On by default; source-agnostic.
- [x] **Offline-first** — live `search` is opt-in per source (default off; `search = true` to
  enable); with Telescope you still get a fuzzy picker over the cache when it's off.
- [x] **ADO scope** — the default fetch and the live search both use `involves me` (assigned
  or created) + active + recent; `project`/`projects` are optional and the default is org-wide,
  and search carries the same scope. `query`/`query_id` remain the per-source override.
- [ ] **Second reference source**: Jira (proves the conventions on a different query language).
