---
id: TASK-11
title: Calendar-event-driven breaks
status: Done
assignee: []
created_date: '2026-11-23T16:18:00Z'
updated_date: '2026-11-23T19:55:00Z'
labels:
  - scheduling
  - calendar
milestone: m-2
dependencies: []
priority: medium
type: feature
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Allow triggering scheduled breaks directly from matching Apple Calendar events (e.g. a dedicated Breaks calendar or matching event title) with accurate start/end tracking.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Users can bind a break schedule to a selected Apple Calendar and optional title filter
- [x] #2 Break starts at event start time, spans event duration, and retains original end time if postponed
- [x] #3 Handles missing/synced calendars and sleep/wake recovery cleanly with unit test coverage
<!-- AC:END -->
