---
status: ratified
anchors: [backend]
avoid_pattern: "\buser\.is_premium\b"
seam: "entitlement.has_feature(user, FEATURE)"
avoid: "raw user.is_premium checks scattered through feature-gating code"
---
## CONV-11 — one entitlement seam (example)

**Example fixture for `speccraft-check` documentation — not a real product
convention.** Illustrates Source A ("grep-bans"): a ratified convention
whose `avoid_pattern` makes it an executable check. `speccraft-check`
greps every file under this convention's `anchors:` (`backend/`) for the
regex; each match becomes a violation, reported with `seam:` as the fix
(`→ USE: entitlement.has_feature(user, FEATURE)`). Add `strict: true` to
this frontmatter to make the convention fail the build unconditionally
(see `session-kit/skills/speccraft-check/SKILL.md`).

Scope note: raw `user.is_premium` reads bypass plan-downgrade and trial
handling — always resolve entitlement through `entitlement.has_feature`,
never by reading the tier flag directly.
