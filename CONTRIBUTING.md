# Contributing to OpenRM

Thanks for your interest. A few project-specific notes before you open a
PR.

## One-time setup: enable the commit guard

This repo ships a tracked pre-commit hook that blocks commits which would
leak personally-identifying or machine-specific data into the public
history. Git does not enable repo-tracked hooks automatically, so after
cloning run:

```bash
git config core.hooksPath .githooks
```

You only need to do this once per clone.

## Why the guard exists

Two things have leaked into this repo before and the hook exists to stop
them recurring:

1. **`DEVELOPMENT_TEAM`.** Opening `OpenRM.xcodeproj` in Xcode silently
   rewrites `DEVELOPMENT_TEAM` in `project.pbxproj` back to *your* Apple
   Developer Team ID. The public project must always keep it empty; set
   your own team in Xcode's Signing & Capabilities tab, but never commit
   it. **Always review the staged `project.pbxproj` diff before
   committing.**

2. **Absolute `/Users/...` paths.** A hardcoded home-directory path
   (e.g. an Xcode-mangled `UILaunchStoryboardName`) leaks a username and
   breaks the build on every other machine. Use bundle-relative
   references (asset catalog names, not filesystem paths).

If the hook blocks a commit it prints the offending staged lines and how
to fix them. In the rare case the match is genuinely benign, you can
override for a single commit:

```bash
OPENRM_ALLOW_PII=1 git commit ...
```

Prefer `OPENRM_ALLOW_PII=1` over `--no-verify`: the former skips only
this guard, the latter disables every hook.

## Scope of contributions

OpenRM's source is GPL-3.0 (see [`LICENSE`](LICENSE)). Do **not** submit
PRs containing decompiled ResMed firmware, decoded proprietary protocol
specifications, or other ResMed-copyrighted material. Reverse-engineered
*field semantics* and independently written decoders are fine; verbatim
proprietary content is not.
