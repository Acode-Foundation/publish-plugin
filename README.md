# Publish Acode plugin

A GitHub Action that publishes your plugin to the [Acode plugin store](https://acode.app/plugins) from CI, using an Acode API key.

```yaml
- uses: Acode-Foundation/publish-plugin@v1
  with:
    api-key: ${{ secrets.ACODE_API_KEY }}
```

## Setup

1. Go to [acode.app/api-keys](https://acode.app/api-keys) and create a key.
   - Keep **Publish updates** checked and pick the plugins this workflow releases.
   - Also check **Submit plugins** if the workflow should create the plugin the first time it runs.
2. In your GitHub repository, open **Settings → Secrets and variables → Actions** and add the key as a secret named `ACODE_API_KEY`.
3. Add a workflow, for example `.github/workflows/publish.yml`:

```yaml
name: Publish to Acode

on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 22

      - run: npm ci
      - run: npm run build # writes plugin.zip

      - uses: Acode-Foundation/publish-plugin@v1
        with:
          api-key: ${{ secrets.ACODE_API_KEY }}
```

Bump `version` in `plugin.json` before each release. acode.app rejects an upload whose version isn't greater than the live one.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `api-key` | required | Your Acode API key. Always pass it from a secret. |
| `zip` | `plugin.zip` | Path to the built plugin zip. The official templates write `plugin.zip` at the repo root. |
| `changelogs` | | Optional. Leave it out to use the changelog inside the zip. Set it to use different text instead. See [Changelogs](#changelogs). |
| `create-if-missing` | `false` | Submit the plugin as new if it doesn't exist yet. Needs the **Submit plugins** permission. Paid plugins must be submitted from the website. |
| `api-url` | `https://acode.app` | Only change this for testing. Plain `http` is refused except for `localhost`. |

## Changelogs

You usually don't need the `changelogs` input. acode.app reads the changelog from your plugin zip, just like a website upload:

- the file named by `changelogs` in `plugin.json`, or
- `changelogs.md` at the root of the zip if `plugin.json` doesn't name one.

The official templates already set `changelogs` in `plugin.json` and pack that file into the zip, so keeping it up to date is enough.

Set `changelogs` only when you want to publish different text for this release. It then replaces the zip's changelog, for example to use the GitHub release notes:

```yaml
      - uses: Acode-Foundation/publish-plugin@v1
        with:
          api-key: ${{ secrets.ACODE_API_KEY }}
          changelogs: ${{ github.event.release.body }}
```

## Outputs

| Output | Description |
| --- | --- |
| `plugin-id` | The id from `plugin.json`. |
| `version` | The version from `plugin.json`. |
| `result` | `published` (live now), `review` (held by the security scan until an admin approves it) or `submitted` (new plugin waiting for approval). |
| `message` | The message returned by acode.app. |

## What happens on acode.app

- Updates to published plugins are scanned exactly like uploads from the website. Risky changes are held for admin review instead of going live, and the job still succeeds with `result: review`.
- Every publish made with a key is emailed to the key owner, with the key name and IP address, so a leaked key gets noticed.
- Keys can't change a plugin's price, manage your account or create other keys. Do those from the website.

## Security

- The key is masked in logs and passed to curl through stdin, so it never shows up in the process list.
- Inputs reach the script through environment variables, never by text substitution, so they can't inject shell commands.
- `changelogs` is sent as text. A value starting with `@` or `<` is not read as a file.
- If a key leaks, revoke it at [acode.app/api-keys](https://acode.app/api-keys). Keys always expire, so set a reminder to rotate it.

## Requirements

Runs on GitHub-hosted Linux and macOS runners. It uses `bash`, `curl`, `unzip` and `node`, which those runners already have.

## Development

```sh
bash test/run.sh
```

The tests run `publish.sh` against a local mock of the acode.app API.

## License

MIT
