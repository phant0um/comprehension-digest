# comprehension-digest

> Turn a repo's recent changes into a **reading** digest that leads with *why*, not *what*. No TTS, no audio.

Fast-moving repos accrue *comprehension debt* — you lose track of what changed and, more importantly, *why*. A `git diff` shows the **what**; the **why** lives in commit messages and PR context. `comprehension-digest` bundles **log + stat + diff** and asks an LLM to lead with intent — and to say "unclear" instead of inventing a motivation when the why isn't there.

Reading-only take on [@mattpocockuk's podcast idea](https://x.com/mattpocockuk).

## Install

```bash
git clone https://github.com/phant0um/comprehension-digest.git
chmod +x comprehension-digest/digest.sh
```

Needs `git`. For auto-generation: `ANTHROPIC_API_KEY` + `curl` + `jq`.

## Usage

```bash
./digest.sh                    # since last digest (else 7 days)
./digest.sh --since "3 days ago"
./digest.sh --since v1.2.0     # any ref/tag/sha works too
./digest.sh --repo ~/code/app
./digest.sh --dry-run          # build prompt only, no API call
./digest.sh --vault            # also copy the digest into your Obsidian vault
./digest.sh --vault ~/notes    # ...into a custom vault dir
./digest.sh --provider ollama  # generate locally via Ollama (no API key)
./digest.sh --provider ollama --model qwen2.5-coder
```

### Providers

| Provider | Endpoint | Key | Default model |
|---|---|---|---|
| `anthropic` (default) | api.anthropic.com | `ANTHROPIC_API_KEY` (required) | `claude-opus-4-8` |
| `ollama` | `OLLAMA_HOST`, default `localhost:11434` | none (`OLLAMA_API_KEY` optional) | `llama3.1` |

Ollama uses the OpenAI-compatible `/v1/chat/completions` endpoint. Runs fully local — no key, no data leaving the machine. Small models degrade on big diffs; cap with `DIGEST_MAX_DIFF_LINES`.

`--vault` writes a second copy with Obsidian frontmatter (tags, dataview-friendly) to `06-GENERATED/digests/` by default. Override with the arg or `DIGEST_VAULT_DIR`. Applies to a generated digest only (API mode), not the prompt fallback.

- With `ANTHROPIC_API_KEY` set → calls the API, writes `.digests/digest_<ts>.md`, and advances a watermark (`.digests/.last` = HEAD sha) so the next run is incremental.
- Without a key (or with `--dry-run`) → writes `.digests/prompt_<ts>.md` for you to paste into Claude.

## Design

- **Diff = *what*, commit log = *why*.** Both are bundled; the model is told to lead with intent and flag when the why is missing rather than hallucinate it.
- **Log kept whole, diff capped** (`DIGEST_MAX_DIFF_LINES`, default 4000). Commit messages are the highest-signal input, so they're never truncated.
- **Incremental** via a HEAD-sha watermark.

Quality of the digest tracks quality of your commit messages. Structured *What & Why* commits → strong digest. `fix stuff` commits → weak one.

## Config

| Env | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | enables auto-generation |
| `DIGEST_PROVIDER` | `anthropic` | `anthropic` or `ollama` |
| `DIGEST_MODEL` | provider default | override model |
| `OLLAMA_HOST` | `http://localhost:11434` | ollama endpoint |
| `DIGEST_MAX_DIFF_LINES` | `4000` | cap diff size (log kept whole) |
| `DIGEST_VAULT_DIR` | `~/Obsidian/vault-michel/06-GENERATED/digests` | `--vault` destination |

## Automate (weekly cron)

```cron
0 9 * * 1  cd ~/code/app && ANTHROPIC_API_KEY=… /path/to/digest.sh
```

## Limits

Good for **awareness** — what moved and why, at a high level. Not a substitute for reading code you're about to edit.

## License

MIT
