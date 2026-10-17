# Lefthook Nix flake

Reusable [Lefthook](https://github.com/evilmartians/lefthook) pre-commit hooks
for a Nix dev shell. Enable the hooks you want; the flake renders them into a
single generated lefthook config with the ordering baked in.

## How it works

`lib.<system>.mkShell { lanes = [ … ]; }` is the primary entry point (the flake
also exposes `lib.<system>.toolchain`, the `nix run` scaffolder, and the wrapper
scripts as `packages.<system>.*`). `lanes` enables whole language lanes;
`hooks.<name>.enable` toggles individual hooks and always wins. It returns a
`pkgs.mkShell` derivation to drop into your own shell's `inputsFrom`. On shell
entry it:

- puts the enabled tools plus `pkgs.lefthook` on `PATH` (and `lefthook-regen`,
  below);
- renders one lefthook config (via `pkgs.formats.yaml`) and, on **first**
  entry, writes it into the project root as `lefthook-generated.yml` — commit
  that file, so the hook definitions travel with the repo and don't depend on
  any machine's Nix store. Entry never rewrites an existing one: when the
  render changes, the shellHook warns and `lefthook-regen` is the explicit
  rewrite (see [Regenerating](#regenerating));
- creates `lefthook.yml` if absent so it `extends` the generated file — and
  warns when an existing `lefthook.yml` doesn't reference it — then runs
  `lefthook install`, reporting any failure.

Committing the config is not the same as installing the hooks. Git never clones
`.git/hooks`, so a **fresh clone has no active hooks** until something runs
`lefthook install` — entering this dev shell does that for you, and new
worktrees of an already-installed repo inherit them. A clone where nobody has
entered the shell commits with no checks at all.

Every hook's `run:` command calls its tool by bare name, resolved from the dev
shell `PATH`, so the generated config is machine-independent. A commit made
outside the dev shell fails loudly with `command not found` instead of
silently running stale or missing tools. Unknown hook names fail at evaluation
with a NixOS-module-style "Did you mean…?" suggestion.

`lefthook-local.yml` is left entirely to you — it is lefthook's own per-user
override file and is merged automatically. Shell entry adds it to
`.git/info/exclude` so it can't be committed by accident.

## Quick setup (no flake input needed)

In any git repository:

```sh
nix run github:Runeword/lefthook
```

That detects which languages the repository contains — from its tracked and
untracked-but-not-ignored files — renders the matching config, writes
`lefthook-generated.yml` + `lefthook.yml`, installs the git hooks and stages
both files. The repository needs no flake input, no dev shell and no direnv.
The lefthook on your `PATH` must be 1.13.0 or newer (see
[`minVersion`](#minversion) for why); the config's `min_version` is stamped
with that floor, not with your local version, so a teammate on an older — but
still supported — lefthook is not locked out.

The config calls its tools by bare name, so they have to be on `PATH` before
the first commit — from a dev shell, or [installed
globally](#installing-the-tools-globally). The scaffolder checks: when some are
missing it names them and prints the exact `nix profile install` command for
the set this config calls. Once they are there, commit the two files.

**`gitleaks` is on by default; `auto-commit` is opt-in** (`--auto-commit`). It
splits every commit into one commit per file and cancels the umbrella commit,
so `git commit` reports failure even when it worked — read
[auto-commit](#auto-commit) before you turn it on.

Anyone who later clones the scaffolded repo needs `lefthook install` once
(or their own `nix run`) — the committed config alone activates nothing.

Detection is overridable:

```sh
nix run github:Runeword/lefthook -- --lanes nix,shell --auto-commit
```

If the repository already ships its own lefthook config — `lefthook.yml`, any of
its `.yaml`/`.json`/`.toml` or dotted variants, or a committed `lefthook-local.*`
(all of which lefthook auto-loads) — the scaffolder writes the generated file
but refuses to install hooks: doing so would activate that file's jobs, `rc` and
`remotes`, which is exactly what git declines to do for a fresh clone. Read it,
then re-run with `--adopt-existing-config`. Since your own config stays in place,
add `lefthook-generated.yml` to its `extends:` list to actually turn the
generated hooks (gitleaks, formatters, auto-commit) on — otherwise only your own
config runs and `lefthook-init` warns you they are inactive.

### Installing the tools globally

`lib.<system>.toolchain` takes the same arguments as `mkShell` and returns the
packages those hooks need, including `lefthook` itself. Derived from
`hooks.nix`, so it cannot drift from the generated config the way a
hand-written list does:

```nix
# home-manager
home.packages = [ … ] ++ inputs.lefthook.lib.${pkgs.stdenv.hostPlatform.system}.toolchain {
  lanes = [ "nix" "shell" "toml" "yaml" ];
  gitleaks = true;
  autoCommit = true;
};
```

Do that once per machine and every repository whose lanes it covers is a
one-command setup. Adding a language later means adding a lane here and
re-running `home-manager switch` — not editing each repository.

Without home-manager, `lib.<system>.toolchainEnv` takes the same arguments and
returns those packages as one environment for your Nix profile — the command
`lefthook-init` prints when tools are missing:

```sh
nix profile install --impure --expr '(builtins.getFlake "github:Runeword/lefthook").lib.x86_64-linux.toolchainEnv { lanes = [ "nix" "shell" ]; gitleaks = true; }'
```

The wrapper scripts are also exposed individually as
`packages.<system>.{auto-commit,security-gitleaks,security-opentofu,lint-nix,lint-go,lint-opentofu}`
(plus `wire-repo` and `lefthook-init`, which are tooling rather than hooks).

## Installation as a flake input

Use this instead when you want the toolchain pinned per repository.

```nix
inputs.lefthook.url = "github:Runeword/lefthook";
```

Then in your dev shell — `lanes` enables every hook in a language lane:

```nix
{ lefthook, pkgs, ... }:
pkgs.mkShell {
  inputsFrom = [
    (lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
      lanes = [ "nix" "shell" ];   # format → lint → security, per lane
      gitleaks = true;
      # autoCommit = true;         # opt-in: read "auto-commit" below first
    })
  ];
}
```

`hooks.<name>.enable` is still available for finer control, and always wins
over what a lane implies:

```nix
lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
  lanes = [ "nix" ];
  hooks.lint-nix.enable = false;   # lane minus one hook
}
```

On first shell entry the flake writes `lefthook-generated.yml` (and a
`lefthook.yml` extending it, if you had none) into the repo — commit both.
Later entries leave both files alone; see
[Regenerating](#regenerating) for what happens when the render changes, and
[the drift check](#the-drift-check) for making CI enforce it.

If you already have a `lefthook.yml` (for `pre-push` jobs, say), add the
generated file to its `extends:` list yourself:

```yaml
extends:
  - lefthook-generated.yml
```

## Ordering (enforced, not by convention)

Hooks are grouped into per-language **lanes** that run in parallel under a
`main` job. Within a lane, jobs are **piped** in `format → lint → security`
order and stop on first failure. `auto-commit` runs afterwards (declared
`finalize`), and `pre-commit` itself is piped — so a failing formatter or
linter blocks `auto-commit` entirely. Formatters carry `stage_fixed`, so their
fixes are staged (lefthook ≥ 2.1.7 does that after the last job; auto-commit
folds them into its commits either way).

All of this is derived from data in `hooks.nix`, so the order is fixed and
cannot drift with how the attrset happens to be enumerated.

### Package-level checks see the staged tree

The checks that read a whole package or module rather than single files
(`lint-go`, `lint-opentofu`, `security-opentofu`) run on a copy of the staged
tree, so an unstaged edit or an untracked file elsewhere in the package cannot
fail a commit, nor make one pass that only works together with it. Where the
working tree matches the index the copy takes the working-tree file, as git
checked it out (decrypted, smudged, your line endings); elsewhere it takes the
staged blob. The staged files come as the formatter left them, and submodules
at their recorded commit.

The copy lives in `${XDG_CACHE_HOME:-~/.cache}/lefthook/staged/<repo>/<hook>/`:
one directory per repository and hook, writable only by you, locked while a
commit uses it, rebuilt on every run and removed afterwards. `lint-go` keeps
golangci-lint's cache there too, so your editor's golangci-lint never sees the
copy's paths. A copy that a killed run (^C) leaves behind is reclaimed by the
next run; idle copies of other repositories are deleted after an hour.

What a tool finds by location still comes from your working tree:
- `lint-go`:
  - the golangci-lint config your working tree would use, including an
    untracked one or one in a parent directory;
  - the active `go.work`, including an untracked one or one above the
    repository;
  - `replace`/`use` paths that point outside the repository;
  - the git-ignored files the linted packages build, as `go list` reports them
    (generated code, cgo headers).
  Untracked files that git does not ignore stay out: those are work in
  progress. golangci-lint can still diff against git, so `new-from-rev` and
  `new-from-merge-base` work.
- `lint-opentofu` and `security-opentofu`: the modules `tofu init` downloaded
  (`.terraform/modules`), and tflint's plugin directory (a relative
  `plugin_dir`, or `./.tflint.d/plugins`), so plugins are installed once, not on
  every commit.

`security-opentofu` scans each directory together with the local modules it
calls, and skips the other root modules below it. If trivy cannot load a module
call, the commit fails (run `tofu init`) instead of the module going unscanned.

Limits:
- git-ignored `*.tfvars` are not read: the check sees what the commit records.
- `go` comes from your project's toolchain on `PATH`.
- If lefthook did not set the unstaged hunks of a partially staged file aside,
  that file's working-tree version is what gets checked. That happens with
  `--no-stage-fixed`, with `--all-files`, and with a 1.x runner whose attempt
  failed.
- Each run copies the whole tree. That takes about a second for 50,000 files.

## Available hooks

| Lane       | Hooks                                                     |
| ---------- | -------------------------------------------------------- |
| `go`       | `format-go`, `lint-go`                                    |
| `lua`      | `format-lua`                                              |
| `nix`      | `format-nix`, `lint-nix`                                  |
| `opentofu` | `format-opentofu`, `lint-opentofu`, `security-opentofu`  |
| `rust`     | `format-rust`                                             |
| `shell`    | `format-shell` (shfmt), `lint-shell`                      |
| `toml`     | `format-toml`                                             |
| `yaml`     | `format-yaml`                                             |
| `zig`      | `format-zig`                                              |
| —          | `security-gitleaks` (repo-wide), `auto-commit` (finalize) |

## Overrides & escape hatches

- `LEFTHOOK=0 git commit …` skips every hook for one commit.
- `LEFTHOOK_EXCLUDE=auto-commit git commit …` skips one job by name (works for
  nested jobs) — the practical way to get a single commit with your own
  message. It matches **job** names, not the hook names in the table above:
  the `format-shell` hook contributes a job named `shfmt`, so excluding it
  takes `LEFTHOOK_EXCLUDE=shfmt`, not `LEFTHOOK_EXCLUDE=format-shell`.
- `git commit --amend --no-verify` is the way to amend, and the same goes for
  `git commit --fixup=<sha>`: a pre-commit hook cannot detect either (the
  environment is byte-identical to a normal commit), so without `--no-verify`
  the change lands as a new commit on top — the amend silently does not happen,
  and a `fixup!` message is replaced, breaking `rebase --autosquash`.
- `lefthook-local.yml` with `pre-commit: { skip: true }` turns the hooks off
  for one clone. Per-job `skip` entries in the local file append to the config
  rather than merging into nested jobs — use `LEFTHOOK_EXCLUDE` for that.
- `hooks.<name>.enable = false` removes one hook from the render for everyone;
  regenerate and commit the config afterwards.

### Removing the hooks

Take the `mkShell` out of the dev shell first: entering it re-installs the
hooks on every entry, so a `lefthook uninstall` on its own is undone silently
the next time anyone enters the directory. Then run `lefthook uninstall`,
delete `lefthook-generated.yml` and `lefthook.yml` (or drop the `extends:`
entry from your own config), and commit. The `lefthook-local.*` lines shell
entry added to `.git/info/exclude` are harmless and can stay. A scaffolded
repository has no shell to remove: `lefthook uninstall` and the two files are
all there is.

Two caveats:

- `lefthook run pre-commit` is not a dry run — the `auto-commit` job creates
  real commits from whatever is staged.
- If an unstaged edit touches the same line a formatter rewrites, lefthook's
  restore of unstaged changes can fail: the commit succeeds and the unstaged
  edit disappears from the worktree, with only a console warning. The content
  survives in the `lefthook auto backup` stash and
  `.git/info/lefthook-unstaged.patch`.

## auto-commit

Splits one `git commit` into one commit per staged file, each with a generated
`Add/Update/Delete <file>` message, then aborts the umbrella commit. It is off
unless you ask for it (`autoCommit = true` in `mkShell`, `--auto-commit` for the
scaffolder).

Consequences worth knowing:

- **`git commit` always exits non-zero, even on success** — its files have
  already been committed individually, so the original commit is cancelled
  (and the umbrella commit message is discarded). The hook's last line says
  which case you are in: `auto-commit: N commits made…` when they landed,
  `…nothing was committed and everything is still staged` when they did not
  (lefthook's summary then shows exit status 3, or the failing command's own).
- The commits land **all at once or not at all**. They are built off to the
  side, and the branch moves once, at the end, and only if nothing else moved
  it (or switched `HEAD` to another branch) meanwhile; that single move is one
  reflog entry, `auto-commit: split into N commits`. If another commit,
  checkout or reset lands during the split, a commit signature fails, or you
  press ^C, nothing is committed and the staging is untouched: run
  `git commit` again.
- Each file is committed from its **staged** blob, so partial staging
  (`git add -p`) is preserved: unstaged hunks stay in the working tree. A file
  that had no unstaged changes when the hook started is committed as it is in
  the working tree instead, so a formatter's fix lands in its own commit even
  on lefthook ≥ 2.1.7, which stages fixes only after this job; the index is
  then brought up to the committed blob. A file the formatter puts back exactly
  as `HEAD` has it gets no (empty) commit.
- Other git activity meanwhile (a `git status` in another terminal, an
  editor's git integration, another terminal unstaging files) cannot break
  it: the real index is written once, after the commits are public, and never
  over a newer staging made in the meantime.
- `commit.gpgSign` is honoured: every per-file commit is signed. The
  per-file commits run no `prepare-commit-msg` or `post-commit` hook.
- Situations where splitting would be wrong pass through untouched as one
  normal commit: concluding a merge, squash-merge, cherry-pick, revert, or
  rebase; `git commit -a` / pathspec commits (git runs those against a
  temporary index); a staged filename containing a tab, newline, quote or
  backslash, which cannot be split safely; and a repository with a
  `commit-msg` or `prepare-commit-msg` hook installed (including one under
  `core.hooksPath`), whose checks the generated messages would bypass.
- A staged filename starting with `:` blocks the commit, with the names
  listed: lefthook hands file names to git as pathspecs, where a leading `:`
  means pathspec magic, so git would act on some other file. Rename it, or
  commit with `--no-verify`.
- `--amend` and `--fixup` are **not** among the pass-throughs — they are
  indistinguishable from a normal commit at hook time. Use `--no-verify` (see
  above).
- One commit per file costs about three git processes per file: a 1,000-file
  commit takes roughly ten seconds.

## Regenerating

The generated config is a committed artifact, so it has to be refreshed when
the hook set or this flake changes:

- **dev-shell repos** — run `lefthook-regen` (on the shell `PATH`, bound to
  that shell's exact render), then commit the result. Re-entering the shell
  does *not* rewrite the file — entry only creates it when missing and prints
  a warning when it has drifted, so a `cd` never rewrites tracked files behind
  your back. The shellHook still warns if `lefthook.yml` stops referencing the
  generated file.
- **scaffolded repos** — re-run `nix run github:Runeword/lefthook -- --force`
  (with the same flags you scaffolded with, `--auto-commit` included).

With auto-commit on, commit a regeneration as one commit:
`LEFTHOOK_EXCLUDE=auto-commit git commit …`. Split per file, the commit that
changes `flake.nix` lands before the one that changes `lefthook-generated.yml`,
and the drift check fails on it.

Both paths render through the same module, so a scaffolded repository and one
wired via `lib.mkShell` with the same hooks and the same `minVersion` produce
byte-identical output. Both stamp the feature floor by default, so that
line matches too; the scaffolder additionally refuses to run if the lefthook on
your `PATH` is below it.

### The drift check

A warning on entry is easy to miss, so the shell's passthru exposes the same
flake check this repo runs on itself: `mkConfigCheck <src>` asserts that the
committed `lefthook-generated.yml` in `<src>` byte-matches the shell's render
(and that lefthook can load it), failing `nix flake check` until you run
`lefthook-regen` and commit. `inputsFrom` does not carry passthru, so keep a
handle on the inner shell:

```nix
let
  lefthookShell = lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
    lanes = [ "nix" "shell" ];
  };
in
{
  devShells.default = pkgs.mkShell { inputsFrom = [ lefthookShell ]; };
  checks.lefthook-config = lefthookShell.mkConfigCheck self;
}
```

A flake in a subdirectory (`nix/flake.nix`) passes its `self` the same way: the
check reads the config from the repository's top level, where the shell writes
it. A flake sees only tracked files, so when the generated file was written but
never added, the check says so instead of asking for a regeneration.

### CI

The drift check proves the committed config is current, not that the code
passes the hooks. `mkHooksCheck <src>` runs the hooks themselves over every
tracked file, as a flake check next to it — a linter failure or a file a
formatter would change fails `nix flake check`:

```nix
checks.lefthook-hooks = lefthookShell.mkHooksCheck self;
```

The build sandbox has no network and no project toolchain, so that check
leaves out `lint-go`, `lint-opentofu` and `security-opentofu` (Go modules,
tflint plugins, trivy's checks bundle) and `auto-commit`; everything else runs,
and `security-gitleaks` scans the whole tree. For the full set, run the hooks
in CI from the dev shell, on a checkout of the commit under test:

```sh
LEFTHOOK_EXCLUDE=auto-commit,auto-commit-prepare \
  lefthook run pre-commit --all-files --fail-on-changes
```

It exits non-zero when a linter fails or a formatter would change a file, and
makes no commits. Without the `LEFTHOOK_EXCLUDE`, a config with auto-commit
would turn every formatter fix into a commit in the CI checkout, and the run
would exit 1 even when everything passed.

`security-gitleaks` scans the staged diff, which is empty in CI, so it passes
without having looked at anything there. Scan the commits the change brings
in with gitleaks itself, e.g. `gitleaks git --log-opts="origin/main..HEAD"`.

### `minVersion`

`min_version` has to describe a lefthook that will **run** the hooks, not the one
that rendered the config — a config demanding a newer lefthook than the runner
fails every commit. It defaults to the feature floor (below), a true lower bound
every supported runner satisfies, rather than this flake's own
`pkgs.lefthook.version`, which would ratchet the requirement upward on every
`nix flake update` and reject older-but-adequate runners. Set it explicitly to
pin a higher minimum:

```nix
lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
  lanes = [ "nix" ];
  minVersion = "2.1.1";   # demand at least this lefthook
}
```

The floor is 1.13.0: `jobs:` needs 1.10.0, but below 1.13.0 the parallel lanes'
post-format `git add` calls race `.git/index.lock` and `stage_fixed` silently
drops the reformatted blobs — an even older lefthook accepts the config and runs
nothing at all. A `minVersion` below the floor is rejected at render time.

### `assertLefthookInstalled`

The shim lefthook installs ends its search for a binary with a bare `echo`, so
once that binary is unreachable — a garbage-collected store path, a fresh clone
with no dev shell entered — the hook prints one line and **exits 0**, letting
the commit through with every check skipped, secret scan included. This stamps
`assert_lefthook_installed`, which turns that branch into an `exit 1`.
`lefthook-init` gets the same protection without patching anything: the setting
travels in the rendered config it writes, so it is baked into the shim as soon as
a root config `extends` that file — which the default path does for you. With
`--adopt-existing-config` it applies only once you have added the `extends:`
entry yourself and re-run `lefthook install`.

It defaults to `true`, on the principle that a hook which checks nothing should
say so rather than pass. Turn it off to restore lefthook's own default:

```nix
lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
  lanes = [ "nix" ];
  assertLefthookInstalled = false;   # missing lefthook = commit proceeds unchecked
}
```

`LEFTHOOK=0 git commit` and `git commit --no-verify` still bypass hooks either
way.

## Adding a hook

Add an entry to `hooks.nix`: exactly one of `lane` + `order`, `standalone`, or
`finalize` (validated at evaluation), the `tools` it needs on `PATH`, and one
or more `jobs` written as verbatim lefthook job attrsets whose `run` calls the
tool by bare name. Formatters set `stage_fixed = true`. That is the only file
to touch — `mk-shell.nix` renders it and the module exposes the
`<name>.enable` option automatically.
