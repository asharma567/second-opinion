# Contributing to second-opinion

Thanks for the interest. This repo is small on purpose — it's a personal-scale skill, not a framework. Contributions are welcome but should preserve that posture: minimal dependencies, shell-first, no abstractions until the third copy-paste forces one.

## Ground rules

- **Shell is the substrate.** Adapters are bash scripts that shell out to CLI tools or curl an HTTP API. No Python/Node runtime, no SDK installs. If you need an SDK, you're probably reaching for the wrong tool.
- **Subscription routing first.** New provider adapters should prefer the provider's official CLI (so the call rides on a paid subscription) over the HTTP API. Document the trade-off in the adapter header.
- **One adapter, one responsibility.** Adapters don't do prompt engineering, output massaging, or fan-out. The dispatcher does that. Adapters take a prompt, return a response, propagate exit codes.
- **Output contract is sacred.** Every adapter prints `=== provider: <name> ===\n<body>\n=== end ===\n` to stdout. Errors to stderr, non-zero exit. The fan-out parser depends on this.
- **No telemetry.** Calls, prompts, and responses stay on the caller's machine. The only network traffic is the call itself.

## Adding a provider adapter

1. Create `scripts/adapters/<provider>.sh` modeled on the smallest existing adapter (`grok.sh` is the cleanest reference).
2. Honor the input shape: read prompt from `$1` (or stdin if `--stdin` flag). Honor `$DEEP_RESEARCH` env var if the provider supports a research mode; otherwise ignore it.
3. Honor the output contract above.
4. Honor the auth pattern: load key from `~/.openclaw-tgpkb/secrets/<provider>_api_key` if the matching env var (`<PROVIDER>_API_KEY`) is unset.
5. Update `scripts/classify.sh` with at least one routing rule that should send work to your provider.
6. Update `scripts/auth-check.sh` so users can verify auth before depending on it.
7. Update `scripts/fanout.sh`'s default provider list if the new provider should participate in fan-outs.
8. Add a routing-table row to `SKILL.md` ("Task shape | Provider | Why").
9. Add a guide at `guide/<provider>.md` if there's anything non-obvious about the auth flow or rate-limit posture.
10. Add at least one test case in `tests/` that covers the classify-routes-to-your-provider path. Don't add a test that calls the live API.

## Style

- Bash strict mode at the top of every script (`set -euo pipefail`).
- Quote every variable expansion. Use `"${var}"`, not `$var`, for anything that could be empty or contain whitespace.
- Errors go to stderr with a clear prefix: `echo "second-opinion: <what failed>" >&2`.
- No `function foo()` syntax. Use `foo() { ... }`.
- Adapters are short. If yours is over ~80 lines, you're probably doing too much in the adapter — push it into the dispatcher.

## Testing

```
./scripts/run-tests.sh
```

This runs offline tests only (classification routing, output contract conformance, argument parsing). Live API tests are not in CI — they need real keys and cost money.

If you want to spot-check a provider locally:

```
./scripts/auth-check.sh                                # confirm your auth
./scripts/dispatch.sh --provider grok "say hi"         # smoke-test one
./scripts/dispatch.sh --fanout "what is 2+2"           # smoke-test fan-out
```

## What we won't merge

- Adapters that add a Python or Node dependency.
- Adapters for providers that require enterprise sales contracts.
- Features that send prompts or responses to any third-party telemetry endpoint.
- Refactors that "abstract" the four-line adapters behind a class hierarchy. They're four lines on purpose.
- Big-bang rewrites. Open an issue first, talk through the design, then send small PRs.

## Releases

Tags follow semver. Bump the version in `SKILL.md` (if/when it gains one) and tag from `main`:

```
git tag -a v0.x.y -m "..."
git push origin v0.x.y
```

No automated release pipeline. This is a skill, not a product.
