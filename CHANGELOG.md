# Changelog

Every update to Lantern goes here, newest first. Version numbers are
`major.minor.patch`: fixes and small improvements bump the last number.
`./lantern.sh version` and the badge next to the name on the page show which one
you're running.

## 1.0.1 — 2026-11-12

**Faster terminal.**

- Output now streams: the shell's output is pushed to the page the moment it's
  printed, instead of the page asking for it every 0.1 s.
- Keys go out immediately. Anything typed while one request is on its way is
  sent together in the next, so fast typing no longer piles up.
- Measured on a home server over Wi-Fi: a key shows in about 160 ms instead of
  210 (worst case 350 ms instead of 620), and 20 keys typed quickly appear in
  0.4 s instead of 0.86 s.

## 1.0.0 — 2026-11-12

First release.

- One page listing your services: up or down, link, CPU and memory, grouped
  into sections. Each service is a few shell commands you give it, with
  templates for systemd, podman, docker and plain processes.
- Buttons per service (Restart, Deploy, anything), shown as text or as one of
  1,600+ icons, optionally right on the table.
- Live logs, and a real terminal in the browser (password prompts, Ctrl-C, tab
  completion).
- CPU, memory, load, Wi-Fi, battery and disk recorded once a minute for 24
  hours: small graphs in the list and the top boxes, 1/6/24-hour charts in a
  Usage tab, and hover text explaining each graph.
- A PIN for anything that changes things, asked once per browser. 5 wrong PINs
  block that IP for 7 days, until Lantern is restarted.
- Light, dark and system themes, a full-page loading shimmer, and a phone layout
  that shows everything the desktop does.
- Two files and nothing to install on Ubuntu/Debian: busybox httpd serves the
  page and runs the script.
