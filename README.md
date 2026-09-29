# KanAI AFM Bridge

*KanAI AFM Bridge* is a tiny OpenAI-compatible server that connects [KanAI](https://github.com/k1bot2026/kanboard-plugin-kanai) for [Kanboard](https://kanboard.org) and your Mac's built-in, on-device AFM model ([Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)).

KanAI talks to the bridge through its `local` provider the same way it talks to Ollama, LM Studio, vLLM, etc., so queries about your projects and tasks get answered privately on your Mac and get displayed in KanAI.

Nothing needs to be installed. No queries or responses get sent to third-party AI services. It's just one Swift file that only uses Apple frameworks and the Command Line Tools.

[![Screenshot](screenshot.png)](Screenshot) _Running KanAI's "Board health" command using the KanAI AFM Bridge with Apple Foundation Models (apple-foundation)._


## Quick start

1. `sh build.sh`
2. `./kanai-afm-bridge` (run it outside any sandbox or the AFM model is unreachable). AFM is prewarmed at startup, and the bridge stays running in the foreground until you stop it with Ctrl-C.
3. `sh test.sh` (from a second terminal) to confirm that everything works: the model answers, JSON mode works, the request guards refuse what they should, and a prompt that asks the model to run commands and delete files only gets prose back.
4. In Kanboard, Settings -> KanAI, set the provider the `local`, Base URL to `http://127.0.0.1:11437/v1`, and model to `apple-foundation`

[INSTALL.md](INSTALL.md) covers requirements, running in the background at login, and the SSH tunnel to a Kanboard server.


## What it does

- Listens on `127.0.0.1:11437` (or change the port with `KANAI_AFM_BRIDGE_PORT`).
- `GET /v1/models` lists one model: `apple-foundation`.
- `POST /v1/chat/completions` responds from the on-device model. `system` messages become the session instructions.
- `response_format` of `json_object` adds a JSON-only instruction, pulls out the first balanced object, validates it, and retries once. A second failure is HTTP 502.
- A long response can hit `max_tokens` before the JSON closes. The bridge then recovers the `answer` string, drops any proposals (a half-written proposal shouldn't ever be applied), and returns `{"answer": ..., "proposals": []}`. The reply may end in the middle of a sentence, and the log line says `SALVAGED`. This applies only when the object never closed and the top-level key is `answer`.
- AFM is a small model that tends to answer in one run-on line, so the bridge's JSON mode also adds a layout rule: line breaks as `\n`, one item per line, `- ` list items, blank lines between paragraphs. A raw line break the model puts inside a JSON string is escaped before validation instead of costing a retry. AFM often ignores the rule, so the bridge reflows the top-level answer string one line at a time. A line of 120 or more characters has its ; items split into - lines (…), and each ". Label:" starts a new paragraph. A paragraph of 200 or more characters with no line breaks and at least two sentence breaks then gets one sentence per paragraph. A sentence with a single semicolon is left alone. Other JSON fields are never changed, and the reply's key order can differ from the model's.
- Each chat reply has a header like `x-kanai-afm-bridge-context: 2870/4096`: the prompt's tokens over the model's context window. Use `curl -i` to show it and make tuning KanAI's max context and max output tokens easier.
- Each request logs the reply's token count. `HIT_MAX_TOKENS` means the reply reached `max_tokens` and was probably cut off.
- Failures are real HTTP errors like `{"error":{"message":...}}`. A failed run doesn't come back as an answer.

Not supported: streaming (HTTP 400), chunked request bodies (HTTP 501), and anything except chat completions and the model list.


## Longer responses

KanAI's command buttons ("Board health", "Project summary", etc.) and its system prompt ask for "concise" and "short" replies, and the on-device model follows them. The 4096-token window is shared, so the reply can use whatever the prompt leaves. To get more:

- Type the length into the question: "Explain in detail with reasons in at least five paragraphs."
- Lower KanAI's max context tokens to leave more room at the cost of fewer tasks in view.
- Raise KanAI's max output tokens and its request timeout, too: replies arrive all at once at roughly 20 tokens per second (estimated from the log), so 1024 tokens is close to a minute. Check `reply_tokens` in the log: `HIT_MAX_TOKENS` means the cap is the limit, and `SALVAGED` means the reply was cut off and recovered.

Longer replies from a model this small may also have more incorrect facts and can take longer.


## Context window

Apple’s on-device foundation model has [a context window of 4096 tokens per session](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window) with a token representing each word or partial word. It's printed as `contextSize` in the startup line. Set KanAI's max context tokens below it with room for the system prompt and `max_tokens`. A prompt over the limit returns HTTP 400 `context_length_exceeded`.


## Security

Built-in:

- No tools are passed to the model, so it can't run commands or touch files.
- Loopback-only. A request with an `Origin` header, or a `Host` other than `127.0.0.1`, `localhost`, or `[::1]`, gets HTTP 403.
- One request at a time, and a queued request keeps waiting (and later generates) even if its client gave up. Header cap 16KB, body cap 128KB, 10s read timeout, 100s generation timeout, 8 open connections.
- Request bodies are never logged. Each request logs one line: status, prompt tokens, reply tokens, attempts, elapsed time.
- Optional bearer token. Set `KANAI_AFM_BRIDGE_TOKEN` and every request without `Authorization: Bearer <token>` gets HTTP 401. Off by default.

Anything that can reach the listener is considered trusted. Through an SSH reverse tunnel, the port opens on the Kanboard server's loopback, so every local user and web app on that server can reach it and not only Kanboard. Worst case scenario is another account using your Mac's model for its own prompts.

On a Kanboard server, every project member's KanAI requests go through the bridge. KanAI's provider, base URL, and model are global settings (`getGlobal()` in KanAI 1.7.0 according to the code and there's no per-user setting. Projects can be switched on or off, but a member in an enabled project can't opt out of the bridge. Their prompts, which include task and project text, are processed on your Mac and need your Mac to be awake. Other members don't need to install anything.

KanAI AFM Bridge never logs request bodies. Its log at `~/Library/Logs/kanai-afm-bridge.log` has one line per request with status, token counts, attempts, and elapsed time, and it records no member, project, or task.

KanAI itself *does* keep the queries and responses on the Kanboard server in the Kanboard database: in the `kanai_messages` table (`content` and `user_id`), with `kanai_conversations`, `kanai_jobs`, and `kanai_proposals`. Conversations get shared with every member of the project, and KanAI's History retention setting defaults to forever according to the KanAI 1.7.0 README and schema. This bridge keeps no record of what project members ask, but whoever controls the Mac running it can change that by replacing the binary or capturing loopback traffic. Treat a Mac running KanAI AFM Bridge as part of the Kanboard's trusted infrastructure and tell Kanboard members that their KanAI prompts are processed there.

The bridge's optional bearer token (`KANAI_AFM_BRIDGE_TOKEN`) doesn't work with KanAI. KanAI's `local` provider builds the client with an empty key and has no key field, so it sends no `Authorization` header accarding to the KanAI 1.7.0 code. Leave the token unset for KanAI.

To keep other server users out, add a firewall rule on the server that lets only the tunnel account and root connect to `127.0.0.1:11437`. The tunnel listener belongs to that account's sshd process. Make the rule persistent, and test it as a different user after applying it.

`firewalld` example:

```
firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -o lo -p tcp -d 127.0.0.1 --dport 11437 -m owner --uid-owner nearhorizon -j ACCEPT
firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 1 -o lo -p tcp -d 127.0.0.1 --dport 11437 -m owner --uid-owner 0 -j ACCEPT
firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 2 -o lo -p tcp -d 127.0.0.1 --dport 11437 -j REJECT
firewall-cmd --reload
```

Also:

- Restrict the tunnel key on the server with `restrict,port-forwarding,permitlisten="127.0.0.1:11437"`. See INSTALL.md.
- An incorrect or deleted key makes the Mac retry every 30s. If the server runs fail2ban, add your Mac's public IP to `ignoreip` for the `sshd` jail or the retries might get it banned.


## Stop, start, and restart

After `sh launchd/install.sh`, use `sh launchd/ctl.sh`:

| Command | Effect |
|---|---|
| `start` | Loads the bridge and the tunnel if they're stopped |
| `stop` | Unloads them until `start`, `restart`, or the next macOS login |
| `restart` | Stop, start, then status |
| `status` | Shows each agent and whether the bridge responds |
| `logs` | Last lines of the bridge's and tunnel's logs |
| `awake on` / `awake off` | Optional. Blocks idle sleep while the agents run. Off by default |

`sh launchd/uninstall.sh` removes the agents for good.


## TODO

- A local usage log: requests, prompt tokens, and time per day, with no task text. KanAI's `kanai:digest` summarizes Kanboard projects but doesn't cover this.
- Privacy ledger: a loopback-only page with today's request count and token totals and no task text. That could be a usage log, too.
- Length hint: an opt-in setting that adds "answer thoroughly" to the JSON-mode instructions.
- Shorter retry: when a JSON reply is cut off at `max_tokens`, the retry asks the model to answer again but more briefly.
- GUI or desktop app: not really necessary, but why not?

## License

GNU General Public License v2. See LICENSE file for details.
