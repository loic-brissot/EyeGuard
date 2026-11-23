---
id: TASK-5
title: Wait for typing & mouse dragging
status: To Do
assignee: []
created_date: '2026-11-23T16:18:00Z'
labels:
  - smart-pause
  - lookaway-inspired
  - timeout-inspired
milestone: m-1
dependencies: []
priority: high
type: feature
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Defer a due break overlay until the user finishes typing or releases an active mouse/trackpad drag gesture so breaks never interrupt mid-sentence or mid-drag.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Due breaks wait for a brief idle-input grace window after the last keystroke or drag release
- [ ] #2 Toggleable in preferences with a bounded maximum wait threshold
- [ ] #3 Unit tests verify deferral and trigger timing using injectable input-activity state
<!-- AC:END -->
