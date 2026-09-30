# Jev Test Bot — Autonomous Exploratory QA Fuzzer

An exploratory web test bot inspired by [qavo](https://github.com/smaldd14/qavo) (by Devin Smaldore) and [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast).

Instead of brittle CSS selectors or slow vision models, the bot uses **TypeSafe's Jev**. This System One decision model traverses web interfaces and detects bugs.

## Reference Links
* **Qavo Repository**: [https://github.com/smaldd14/qavo](https://github.com/smaldd14/qavo)
* **Qavo Technical Deep-Dive**: [https://smaldore.dev/blog/qavo/qavo-qa-agent-with-typed-choices](https://smaldore.dev/blog/qavo/qavo-qa-agent-with-typed-choices)
* **TypeSafe Jev Documentation**: [https://docs.typesafe.ai](https://docs.typesafe.ai)
* **Jev Ultrafast**: [https://github.com/browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast)

## How It Works

1. **Atomic DOM Snapshotting**: Each turn snapshots the current page, extracting all visible and interactive controls into an indexed action space (`[1] button`, `[2] link`, `[3] textbox`).
2. **System One Typed Decisions**: The agent queries Jev with structured questions (`operation`, `CLICK_target`, `expect`). Jev returns typed choices with calibrated confidence probabilities in a single round-trip (~70ms).
3. **Bug Detection Oracles**: Monitors:
   * **HTTP & Network Status**: Catches 4xx/5xx responses from the frontend or backend APIs.
   * **Console & Runtime Errors**: Intercepts unhandled exceptions and console error events.
   * **Crash Boundaries**: Scans for React error boundaries, "Something went wrong" crash cards, and unexpected application errors.
4. **Safety & Scope Limiters**:
   * Guards against destructive targets (e.g. automatically avoids clicking "Sign out" / "Log out").
   * Enforces area prefix scoping (`--area`) so the bot tests specific modules without wandering off.
   * Hard limits on max turns (`--max-turns`) and overall execution time (`--timeout`).

## Secret Management

The bot looks for TypeSafe credentials in the following order:
1. `TYPESAFE_API_KEY` or `JEV_API_KEY` environment variables.
2. In bash via `get-secrets JEV TYPESAFE` (sources `~/.andy_sync/includes/function-base-2023.sh` if available).
3. If no key is set or the sandbox is offline, it activates the **Calibrated System One Simulator** (`--mock`). This permits offline runs without crashing.

## CLI Usage

```bash
# Run against the default Tailscale deployment (scoping to all routes, 10 turns)
python3 scripts/jev-test-bot/bot.py --url https://ftna-signalloom.taild4da3.ts.net/ --max-turns 10

# Scope to a specific module (e.g., AgentMaxxing console)
python3 scripts/jev-test-bot/bot.py --area /demos/agentmaxxing --max-turns 5

# Stop immediately upon first detected bug
python3 scripts/jev-test-bot/bot.py --stop-on-error

# Run in offline simulation / mock mode
python3 scripts/jev-test-bot/bot.py --mock
```

## Make Targets

You can run the bot directly using make:

```bash
# Default run (10 turns against Signal Loom)
make test-bot

# Custom area and turn limits
make test-bot AREA=/demos/agentmaxxing TURNS=5

# Custom target URL
make test-bot URL=http://localhost:5173 TURNS=15

# Force mock simulation mode
make test-bot MOCK=true
```
