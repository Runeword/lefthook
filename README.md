# Lefthook remote configs
A collection of reusable [Lefthook](https://github.com/evilmartians/lefthook) configurations that can be shared across multiple projects.

## Installation
First install [lefthook](https://github.com/evilmartians/lefthook), then in the current git repository :

1. Create a lefthook.yml config file
```shell
cat <<EOF > lefthook.yml
remotes:
  - git_url: https://github.com/Runeword/lefthook
    configs:
      - precommit-auto-msg.yml
EOF
```

2. Install git hooks defined in the lefthook config
```shell
lefthook install
```
