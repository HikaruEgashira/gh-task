<h1 align="center">gh-task</h1>

<p align="center">
  Kanban-based task manager for the GitHub CLI.
</p>

---

gh-task manages tasks in a plain `TASKS.md` markdown file stored in your repository.
Columns are defined by `## Headers` — no configuration files, no databases, no external services.
Bidirectional sync with GitHub Projects is supported via `push` and `pull`.

> [!NOTE]
>
> Written in Zig. Single static binary, zero dependencies.

## Install

```sh
gh extension install HikaruEgashira/gh-task
```

## Usage

```sh
gh task add "Implement auth"              # Add to first column
gh task add "Fix bug" -s "In Progress"    # Add to specific column
gh task ls                                # Kanban board view
gh task view                              # List view grouped by column
gh task move 1 done                       # Move task (case-insensitive)
gh task edit 1 "New title"                # Rename
gh task rm 1                              # Remove
gh task columns                           # List columns
```

### GitHub Projects sync

```sh
gh task pull <owner> <project-number>     # Import from GitHub Projects
gh task push <owner> <project-number>     # Export to GitHub Projects
```

## TASKS.md format

```markdown
# Tasks

## Todo

- [ ] Implement auth <!-- id:1 -->
- [ ] Write tests <!-- id:2 -->

## In Progress

- [ ] Fix login bug <!-- id:3 -->

## Done

- [x] Initial setup <!-- id:4 -->
```

Columns are read from `## Headers`. Tasks are standard checkbox items.
ID comments (`<!-- id:N -->`) are managed automatically — hand-edited files without IDs work fine.

## Build from source

```sh
zig build -Doptimize=ReleaseSafe
```

## Verify release integrity

All release binaries include [SLSA provenance attestations](https://slsa.dev/):

```sh
gh attestation verify $(which gh-task) --repo HikaruEgashira/gh-task
```

## License

[MIT](LICENSE)
