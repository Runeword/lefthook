# Lefthook remote configs
A collection of reusable [Lefthook](https://github.com/evilmartians/lefthook) configurations that can be shared across multiple projects.

## How to use
First install [lefthook](https://github.com/evilmartians/lefthook), then in the current git repository :

1. Create a lefthook.yml file
```yaml
remotes:
  - git_url: https://github.com/Runeword/lefthook
    configs:
      - precommit-auto-msg.yml
```
2. Run `lefthook install`
