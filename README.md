# EyeGuard

**Gentle, flow-aware 20-20-20 screen breaks for macOS.**

[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

EyeGuard is designed to reduce digital eye strain and screen fatigue by encouraging regular short pauses throughout the workday. The goal is to follow the optometrist-recommended **20-20-20 rule**: every 20 minutes, look at something 20 feet away for 20 seconds. EyeGuard gently blocks your displays with a calm screensaver overlay that can be snoozed or skipped whenever needed. Everything runs locally on your Mac with zero accounts, subscriptions, or cloud telemetry.

## Origin, Inspirations & Alternatives

EyeGuard is a fork of **[TwentyGuard](https://github.com/JavenGroup/TwentyGuard)** (MIT-licensed), building on its lean native Swift/AppKit core, multi-monitor overlay engine, and local SQLite compliance tracking to add a calmer screensaver experience, optional break skipping, and flow-aware smart pausing.

EyeGuard draws inspiration from, and sits alongside, several great macOS and cross-platform break reminder apps:

- **[LookAway](https://lookaway.com/)** — Polished native macOS break app known for zero-config Smart Pause (mic, typing, dragging, fullscreen), wellness nudges, and iPhone sync.
- **[Time Out](https://www.dejal.com/timeout/)** — Long-standing, deeply configurable native macOS break engine with rich themes, rules, and break actions.
- **[Pomy](https://apps.apple.com/us/app/pomy-lite-2/id6444042376)** — Minimalist native macOS 20-20-20 menu bar timer with a simple dismissible overlay.
- **[DeskRest](https://deskrest.com/)** — Native macOS break reminder featuring posture alerts, guided exercises, and context-aware pausing.
- **[Stretchly](https://hovancik.net/stretchly/)** — Popular free, open-source, cross-platform break reminder supporting mini and long breaks.
- **[BreakTimer](https://breaktimer.app/)** — Free, open-source, cross-platform timer focused on simple schedules and working-hours limits.

## Current Features

Inherited from the TwentyGuard baseline (see [`backlog/`](backlog/) for the EyeGuard roadmap):

- **Multi-monitor break overlay**: full-screen rest window covering every connected display.
- **20-20-20 & custom rhythms**: default 20 min work / 20 s break, or custom intervals (10–60 min work, 10 s–10 min break).
- **Postpone controls with caps**: postpone by 1, 2, or 5 minutes (`⌘1`, `⌘2`, `⌘5`) within configurable cumulative limits.
- **Temporary disable**: pause reminders for 1 hour (`⌘D`) during meetings or focused sessions, with automatic resumption.
- **Sleep & lock awareness**: resets to a fresh work cycle automatically after sleep, screen lock, or screensaver wake.
- **Eye health report**: local SQLite verdict-first dashboard with daily, 7-day, and monthly views (`⌘S`).
- **Night screen lock**: optional evening screen-time boundary with a timed override flow.
- **Local-first & multilingual**: zero network dependency, supporting English, Simplified Chinese, Spanish, Japanese, and Korean.

## Roadmap

Roadmap planning lives in [`backlog/`](backlog/) using [Backlog.md](https://github.com/MrLesk/Backlog.md). Run `backlog task list` to view upcoming milestones, including the EyeGuard target rebrand, skippable screensaver overlay, pre-break heads-up, custom themes, and Smart Pause rules.

## Build From Source

> **Note:** Until the initial codebase rebrand task is completed, Swift package targets and build artifacts still use the upstream `TwentyGuard` identifiers.

Requirements:

- macOS 12.0+
- Xcode Command Line Tools (Swift 5.9+)

```bash
git clone https://github.com/loic-brissot/EyeGuard.git
cd EyeGuard
make build
make run
```

Build and install the standalone app bundle:

```bash
make build-app
make install
make launch
```

Run tests and package verification:

```bash
make test
make test-lifecycle
make dmg
```

## Privacy

EyeGuard requires no network access, account, or analytics service. All preferences, logs, and break statistics stay strictly local on your Mac.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for our branching workflow, PR guidelines, testing protocol, versioning, and release notes standard.

## License

MIT License. See [LICENSE](LICENSE).
